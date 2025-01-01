#!/usr/bin/env ruby

require 'osgb_convert'
require 'quadkey'
require 'webrick'
require 'open-uri'
require 'fileutils'
require 'concurrent'
require 'down'
require 'yaml'
require 'mime/types'
require 'nokogiri'
require 'attr_extras'
require_relative 'lib/pair'
require_relative 'lib/os'

def hash_by(*entries, default: nil, field: :id)
  hash = {}
  entries.each do |entry|
    hash[entry.send(field)] = entry
  end
  hash.default = hash[default] || entries.first
  hash
end

class PageSize < Dimensions
  def initialize(id, width, height, name)
    super(width, height)
    @id = id
    @name = name
  end
  attr_value :id, :name, :width, :height
end

PAPER_SIZES = hash_by(
  PageSize.new('A5', 21.0, 14.8, 'A5 landscape'),
  PageSize.new('A5-portrait', 14.8, 21.0, 'A5 portrait'),
  PageSize.new('A4', 29.7, 21.0, 'A4 landscape'),
  PageSize.new('A4-portrait', 21.0, 29.7, 'A4 portrait'),
  PageSize.new('A3', 42.0, 29.7, 'A3 landscape'),
  PageSize.new('A3-portrait', 29.7, 42.0, 'A3 portrait'),
  default: 'A4'
)

$w = 2
$h = 2

def parse_config
  {
    port: ENV['ATLAS_PORT'] || 5000,
    rc_file: ENV['ATLAS_RC'] || 'atlasrc.yaml',
    address: ENV['ATLAS_ADDRESS'] || '0.0.0.0',
    offline: !ENV['ATLAS_OFFLINE'].empty?
  }
end

PageSetup = Struct.new(
  :paper, # cm x cm
  :scale, # cm/km
  :page_margin, # cm
  :grid_north, # bool
  :grid_lines, # bool
) do
  def initialize(*)
    super
    @axis = Dimensions[0.75, 0.5]
    @overlap = 2.0 # cm
  end
  attr_reader :axis

  def inner # cm x cm
    paper - page_margin * 2
  end

  def map # cm x cm
    inner - axis * 2
  end

  def safe_map # cm x cm
    map - @overlap
  end

  def scaled_map # km x km
    map / scale
  end

  def scaled_safe_map # km x km
    safe_map / scale
  end
end

class CoordinateSystem
  def from_ll(ll)
    fail NotImplementedError, "parse a lat-long pair"
  end

  def to_ll(osref)
    fail NotImplementedError, "Export a lat-long pair"
  end
end

class OSGrid < CoordinateSystem
  def ll_to_en(ll)
    latlong = OsgbConvert::WGS84.new(ll.lat, ll.long, 0)
    grid = OsgbConvert::OSGrid.from_wgs84(latlong)
    Pair[grid.easting, grid.northing].round
  end

  def en_to_ll(easting, northing)
    grid = OsgbConvert::OSGrid.new(easting, northing)
    latlong = grid.wgs84
    LongLat[latlong]
  end

  def from_ll(ll)
    easting, northing = ll_to_en(ll)
    OSRef.to_ref(easting, northing)
  end

  def to_ll(osref)
    easting, northing = OSRef.parse_ref(osref)
    en_to_ll(easting, northing)
  end

  # Find the coordinates of a certain corner of the grid square of size skip meters
  # ```
  # (0,1)---------(1,1)
  #   |             |
  #   |             |
  #   |  x <-point  |
  #   |             |
  # (0,0)---------(1,0)
  # ```
  def corner(ll, dx = 0, dy = 0, skip = 1000)
    coords = (ll_to_en(ll) / skip).floor * skip
    en_to_ll(* coords + Pair[dx, dy] * skip)
  end
end

# Allow splatting nil
class NilClass
  def to_hash
    {}
  end

  def empty?
    true
  end
end

class TileServer
  def initialize(id:, folder:, title: nil, grid_lines: false, grid_north: false, zoom: nil, zooms: nil, scale: 0, hidden: false, cache_size: 0)
    @id = id
    @folder = folder
    @grid_lines = grid_lines
    @grid_north = grid_north
    @scale = scale
    @hidden = hidden
    @cache_size = cache_size
    @title = title || id
    @zooms = zooms || (zoom.nil? ? 8..16 : [zoom])
    @zoom = closest_zoom(zoom || 14)
  end

  attr_reader :id, :folder, :grid_lines, :grid_north, :title, :zoom, :zooms, :scale, :hidden, :cache_size

  def proxy_to_tile(tile)
    "/tile/#{id}/#{tile}"
  end

  # number of kilometers per tile each way
  # @param center [LongLat]
  def scale_factor_at(center)
    tile = from_ll(center)

    square_left = center
    square_right = center.move(1000, 0)

    tile_left = to_ll(tile)
    tile_right = to_ll(move(tile, 1, 0))

    tile_left.distance_to(tile_right) / square_left.distance_to(square_right)
  end

  def proportion(tile, point)
    top_left = to_ll(tile)
    top_right = to_ll(move(tile, 1, 0))
    bottom_left = to_ll(move(tile, 0, 1))

    right = top_right - top_left
    down = bottom_left - top_left

    to_point = point - top_left

    to_point.as_linear_combination(right, down)
  end

  def closest_zoom(zoom)
    if zoom.nil?
      @zoom
    elsif @zooms.include? zoom
      @zooms.is_a?(Range) ? zoom.round : zoom
    elsif @zooms.min > zoom
      @zooms.min
    elsif @zooms.max < zoom
      @zooms.max
    else
      i = @zooms.bsearch_index { |x| x >= zoom }
      @zooms[i] - zoom <= zoom - @zooms[i - 1] ? @zooms[i] : @zooms[i - 1]
    end
  end

  def with_zoom(zoom = nil)
    zoom = zoom.to_i unless zoom.nil?
    new_zoom = closest_zoom(zoom)
    if new_zoom == @zoom
      self
    else
      new_with_zoom(new_zoom)
    end
  end
end

class QuadkeyTileServer < TileServer
  def initialize(url:, **rest)
    super(**rest)
    @url = url
    @mime = 'image/jpeg'
    @extension = 'jpg'
  end

  attr_reader :mime

  def new_with_zoom(zoom)
    QuadkeyTileServer.new(url: @url, id: id, folder: @folder, hidden: @hidden, cache_size: @cache_size, zoom: zoom, zooms: @zooms, grid_lines: grid_lines, grid_north: grid_north)
  end

  def path_to_tile(quadkey)
    "#{quadkey}.#{@extension}"
  end

  def url_to_tile(quadkey)
    format(@url, quadkey)
  end

  def move_one(q, negative = false, dimension = 1)
    pre = q[0..-2]
    return '' if q.empty?

    tail = q[-1].to_i
    new_pre = ((tail & dimension) == 0) ^ negative ? pre : move_one(pre, negative, dimension)
    new_pre + (tail ^ dimension).to_s
  end

  def move(q, dx, dy)
    while dx > 0
      q = move_one(q, false, 1)
      dx -= 1
    end

    while dx < 0
      q = move_one(q, true, 1)
      dx += 1
    end

    while dy > 0
      q = move_one(q, false, 2)
      dy -= 1
    end

    while dy < 0
      q = move_one(q, true, 2)
      dy += 1
    end

    q
  end

  def from_ll(ll)
    Quadkey.encode(ll.lat, ll.long, @zoom)
  end

  def to_ll(q)
    lat, long = Quadkey.decode(q)
    LongLat[long, lat]
  end
end

class StreetMapTileServer < TileServer
  def initialize(url:, lookup_url:, tile_size:, **rest)
    super(grid_lines: false, grid_north: false, **rest)
    @url = url
    @lookup_url = lookup_url
    @mime = 'image/gif'
    @extension = 'gif'
    @tile_size = tile_size

    @coordinate_system = OSGrid.new
  end

  attr_reader :mime, :lookup_url, :tile_size

  def joiner
    '_'
  end

  def new_with_zoom(_zoom)
    self
  end

  def path_to_tile(smref)
    "#{smref}.#{@extension}"
  end

  def url_to_tile(smref)
    uri = URI(lookup_url % to_os(smref).join('|'))
    _, rest, tile = uri.open(ssl_verify_mode: OpenSSL::SSL::VERIFY_NONE) do |f|
      f.lazy.drop(2).next.split('@')
    end
    format(@url, tile, rest)
  end

  def floor(x)
    ((x / tile_size).floor * tile_size).to_i
  end

  def move(smref, dx, dy)
    easting, northing = to_os(smref)
    from_os(
      easting + dx * tile_size,
      northing - dy * tile_size
    )
  end

  def scale_factor_at(_center)
    tile_size / 1000.0
  end

  def from_os(easting, northing)
    [easting, northing].map(&method(:floor)).join(joiner)
  end

  def to_os(smref)
    smref.split(joiner).map(&:to_i)
  end

  def from_ll(ll)
    from_os(*@coordinate_system.ll_to_en(ll))
  end

  def to_ll(smref)
    @coordinate_system.en_to_ll(*to_os(smref))
  end
end

class ZXYTileServer < TileServer
  def initialize(url:, **rest)
    rest[:zooms] ||= url.keys if url.is_a? Hash
    super(**rest)
    @url = url
    @mime = 'image/jpeg'
    @extension = 'jpg'
  end

  attr_reader :mime

  def new_with_zoom(zoom)
    self.class.new(url: @url, id: id, folder: @folder, hidden: @hidden, cache_size: @cache_size, zoom: zoom, zooms: @zooms, grid_lines: grid_lines, grid_north: grid_north)
  end

  def split(zxy)
    zxy.split('/').map(&:to_i)
  end

  def join(z, x, y)
    [z, x, y].join('/')
  end

  def path_to_tile(zxy)
    "#{zxy.gsub('/', '-')}.#{@extension}"
  end

  def url(z=0)
    if @url.is_a? Hash
      @url[z]
    else
      @url
    end
  end

  def url_to_tile(zxy)
    z, x, y = split(zxy)
    url(z)
      .gsub(/\{((?:\w+\|)+\w+)\}/) { Regexp.last_match(1).split('|').sample }
      .gsub(/\{(\w)\}/) { { 'z' => z, 'x' => x, 'y' => y }[Regexp.last_match(1)] }
  end

  def move(zxy, dx, dy)
    z, x, y = split(zxy)
    join(z, x + dx, y + dy)
  end

  def from_ll(ll)
    z = @zoom
    lat_rad = ll.lat / 180 * Math::PI
    n = 2.0**z
    x = ((ll.long + 180.0) / 360.0 * n).to_i
    y = ((1.0 - Math.log(Math.tan(lat_rad) + (1 / Math.cos(lat_rad))) / Math::PI) / 2.0 * n).to_i
    join(z, x, y)
  end

  def to_ll(zxy)
    z, x, y = split(zxy)

    n = 2.0**z
    long = x / n * 360.0 - 180.0
    lat_rad = Math.atan(Math.sinh(Math::PI * (1 - 2 * y / n)))
    lat = 180.0 * (lat_rad / Math::PI)
    LongLat[long, lat]
  end
end

class TmsTileServer < ZXYTileServer
  def url_to_tile(zxy)
    z, x, y = split(zxy)
    url(z)
      .gsub(/\{((?:\w+\|)+\w+)\}/) { Regexp.last_match(1).split('|').sample }
      .gsub(/\{(\w)\}/) { { 'z' => z, 'x' => x, 'y' => ((2**z).to_i - 1 - y) }[Regexp.last_match(1)] }
  end
end

def terminal_response(center, tile_server)
  Dir.chdir(File.dirname(__FILE__))
  center_tile = tile_server.from_ll(OSGrid.new.to_ll(center))
  (-$h..$h).each do |y|
    line = (-$w..$w).map do |x|
      tile_server.move(center_tile, x, y)
    end
    system("./imgrow -u #{line.map { |cell| tile_server.url_to_tile(cell).inspect }.join(' ')}")
  end
end

def neighbours(center, w, h)
  up = center.move(0, h)
  down = center.move(0, -h)
  left = center.move(-w, 0)
  right = center.move(w, 0)

  [up, down, left, right]
end

def calculate_centers(points, padding, page_setup)
  refs = points.map { |ref| OSRef.parse_ref(ref) }
  easting_limits = refs.map { |ref| ref[0] }.minmax
  northing_limits = refs.map { |ref| ref[1] }.minmax
  mid = Pair[easting_limits.reduce(:+) / 2.0, northing_limits.reduce(:+) / 2.0]
  range = Pair[
    easting_limits[1] - easting_limits[0], # (m)
    northing_limits[1] - northing_limits[0], # (m)
  ] / 1000.0 + padding # (km)

  counts = (range / page_setup.scaled_safe_map).floor

  min = mid - (page_setup.scaled_safe_map * 1000 * counts / 2) # m

  [counts.each_yx.map do |y, x|
    OSRef.to_ref(* min + page_setup.scaled_safe_map * [x, y] * 1000)
  end, *(counts + 1)]
end

def web_head(page_setup)
  %(
    <html>
    <head>
      <title>
        Atlas: OS Maps for printing
      </title>
      <style>
        :root {
          --page-width: #{page_setup.map.width}cm;
          --page-height: #{page_setup.map.height}cm;
          --easting-axis: #{page_setup.axis.height}cm;
          --northing-axis: #{page_setup.axis.width}cm;
        }

        @page {
          margin: #{page_setup.page_margin}cm;
          size: #{page_setup.paper.name};
        }
      </style>
      <link rel="stylesheet" href="atlas.css" />
      <script src="./atlas.js"></script>
    </head>
  )
end

def corner_label(center, dx, dy, page_setup)
  # TODO: where the coordinate system comes from
  corner = center.move(* page_setup.scaled_map * [dx, dy] * 1000 / 2)
  OSGrid.new.from_ll(corner)[0...2]
end

def web_response_single(center, tile_server, page_setup, minimap = '')
  centerTile = tile_server.from_ll(center)

  scale_factor = tile_server.scale_factor_at(center)

  skip = case page_setup.scale
         when 1.. then 1
         when 0.5.. then 5
         when (1.0 / 8).. then 10
         else 20
         end

  pos_in_cell = tile_server.proportion(centerTile, center)

  res = StringIO.new

  up, down, left, right = neighbours(
    center,
    *page_setup.scaled_safe_map * 1000 # in meters
  )

  # Get the position of a certain corner of the center grid square, as a proportion of the center tile
  # (dx, dy):
  # (0,1)--(1,1)
  #   |      |
  # (0,0)--(1,0)
  # TODO: what are tiles? I’ll hardcode OS for now
  coordinate_system = OSGrid.new
  corner_of_center_square = lambda do |dx, dy|
    tile_server.proportion(centerTile, coordinate_system.corner(center, dx, dy, skip * 1000))
  end

  cell_side = corner_of_center_square[0, 0] - corner_of_center_square[0, 1]
  true_north = cell_side.angle_from_vertical

  res << %(
    <div class="page"
      data-center="#{coordinate_system.from_ll(center)}"
      data-easting="#{coordinate_system.ll_to_en(center).x}"
      data-northing="#{coordinate_system.ll_to_en(center).y}"
      data-north="#{coordinate_system.from_ll(up)}"
      data-south="#{coordinate_system.from_ll(down)}"
      data-west="#{coordinate_system.from_ll(left)}"
      data-east="#{coordinate_system.from_ll(right)}"
      data-skip="#{skip}"
    >
      <div class="map-frame">
        <style>
          .page[data-center='#{coordinate_system.from_ll(center)}'] table img {
            width: #{page_setup.scale * scale_factor}cm;
            height: #{page_setup.scale * scale_factor}cm;
          }
        </style>
        <div class="grid-letters top left">#{corner_label(center, -1, 1, page_setup)}</div>
        <div class="grid-letters bottom left">#{corner_label(center, -1, -1, page_setup)}</div>
        <div class="grid-letters top right">#{corner_label(center, 1, 1, page_setup)}</div>
        <div class="grid-letters bottom right">#{corner_label(center, 1, -1, page_setup)}</div>
        <div class="border vertical pre"></div>
        <div class="border vertical post"></div>
        <div class="border horizontal pre"></div>
        <div class="border horizontal post"></div>
        #{minimap}
        <div class='map'>
          <table
            style="margin-top: #{-page_setup.scale * scale_factor * pos_in_cell.y}cm;
                    margin-bottom: #{-page_setup.scale * scale_factor * (1 - pos_in_cell.y)}cm;
                    margin-left: #{-page_setup.scale * scale_factor * pos_in_cell.x}cm;
                    margin-right: #{-page_setup.scale * scale_factor * (1 - pos_in_cell.x)}cm;
                    #{page_setup.grid_north ? "transform: rotate(#{true_north}rad);" : ''}
                    transform-origin:
                      calc(50% + #{page_setup.scale * pos_in_cell.x}cm / 2 - #{page_setup.scale * (1 - pos_in_cell.x)}cm / 2)
                      calc(50% + #{page_setup.scale * pos_in_cell.y}cm / 2 - #{page_setup.scale * (1 - pos_in_cell.y)}cm / 2);"
          >
  )
  # TODO: check if extra is needed if we are very diagonal, e.g. at NV1070880909
  tile_grid = (page_setup.scaled_map / 2.0 / scale_factor).ceil
  (-tile_grid.height..tile_grid.height).each do |y|
    res << '<tr>'
    (-tile_grid.width..tile_grid.width).each do |x|
      cell = tile_server.move(centerTile, x, y)
      is_center = y == 0 && x == 0
      res << '<td '
      res << "class='center'" if is_center
      res << '>'
      if is_center
        %w[bottom top].each_with_index do |vertical, y|
          %w[left right].each_with_index do |horizontal, x|
            left, top = corner_of_center_square[x, y]
            res << %(
              <div
                class='corner #{vertical} #{horizontal}'
                style='left: #{left * 100}%; top: #{top * 100}%;'
                data-left='#{left}'
                data-top='#{top}'
              ></div>
            )
          end
        end
        res << "<div
            class='corner'
            style='left: #{pos_in_cell.x * 100}%; top: #{pos_in_cell.y * 100}%;'
          ></div>"
        res << "<div class='grid-lines'></div>" if page_setup.grid_lines
      end
      res << %(<img src="#{tile_server.proxy_to_tile(cell)}" alt="#{cell}">)
      res << '</td>'
    end
    res << '</tr>'
  end
  res << %(
            </table>
          </div>
        </div>
      </div>
  )
  res.string
end

def minimap(page_setup, centers, index, coordinate_system, xcount, ycount)
  return '' unless xcount * ycount > 1

  minimap = StringIO.new
  minimap << '<table class="minimap"'

  height = page_setup.axis.height
  minimap << "  style='height: #{height}cm; width: #{height.to_f * xcount / ycount}cm'"
  minimap << '>'
  (0...ycount).each do |y|
    minimap << '<tr>'
    (0...xcount).each do |x|
      i = y * xcount + x
      minimap << '<td '
      minimap << 'class="this" ' if index == i
      minimap << "data-center='#{coordinate_system.from_ll(centers[i])}' "
      minimap << '>'
      minimap << '</td>'
    end
    minimap << '</tr>'
  end
  minimap << '</table>'
  minimap.string
end

def controls(chosen_tile_server, page_setup, raw_req)
  Nokogiri::HTML::Builder.new do |doc|
    input = lambda { |name, value, type: :hidden, autocomplete: :off, **attrs|
      doc.input(type: type, name: name, autocomplete: autocomplete, value: value, **attrs,
                **({ disabled: true } if value.nil?))
    }
    option = lambda { |text, value, selected_value, **attrs|
      doc.option(text, value: value, **attrs, **({ selected: true } if value == selected_value))
    }

    doc.div(class: 'controls') do
      doc.div(class: 'print-controls') do
        doc.button('Print', onclick: 'window.print()', class: 'print-button')
      end
      doc.form(action: '/') do
        doc.div(class: 'flex-together') do
          doc.select(name: :style, autocomplete: :off) do
            $tile_servers.values.each do |tile_server|
              if !tile_server.hidden || tile_server.id == chosen_tile_server.id
                option[tile_server.title, tile_server.id, chosen_tile_server.id,
                      'data-zooms': tile_server.zooms.to_a, 'data-scale': tile_server.scale]
              end
            end
          end
          current_zoom = chosen_tile_server.zoom
          increments = chosen_tile_server.zooms.each_cons(2).map { |a, b| b - a }.to_a.uniq
          equal_increments = increments.size <= 1
          doc.label(class: ['zoom-control',
                            *([:invisible] if chosen_tile_server.zooms.size <= 1)].join(' ')) do
            doc.span('Zoom')
            input[:zoom, current_zoom, type: :number,
                                       min: chosen_tile_server.zooms.min || 0,
                                       max: chosen_tile_server.zooms.max || 0,
                                       **({ step: increments.first } if equal_increments),
                                       **({ disabled: true, class: :hidden } unless equal_increments),
                                       style: 'width: 4em']
            doc.select(class: ['zoom-dropdown', *([:hidden] if equal_increments)].join(' '),
                       autocomplete: :off,
                       style: 'width: 4em') do
              chosen_tile_server.zooms.each do |zoom|
                option[zoom, zoom, current_zoom]
              end
            end
          end
        end
        doc.label(class: 'scale-control') do
          doc.span('Scale: ')
          doc.div.range do
            doc.div do
              doc.input(type: :hidden, name: 'scale', value: page_setup.scale, autocomplete: :off)
              doc.input(type: :range, value: Math.log2(page_setup.scale), min: -4, max: 4, step: 1, autocomplete: :off)
            end

            doc.span do
              doc.span('%g' % [1, page_setup.scale].max, id: 'scale-reading')
              doc.text ' cm : '
              doc.span('%g' % [1, 1 / page_setup.scale].max, id: 'scale-reading-reciprocal')
              doc.text ' km'
            end
          end
        end

        input_types = %i[fit center]
        selected_input_type = input_types.find { |key| raw_req[key] }
        position_input = raw_req[selected_input_type] || ''

        doc.div(class: 'flex-together') do
          input_types.each do |input_type|
            doc.label do
              input[:input_type, input_type,
                    type: :radio, autocomplete: :off,
                    **({ checked: true } if input_type == selected_input_type)]
              doc.span("#{input_type.to_s.capitalize} ", title: "Comma-separated")

              input[input_type, (position_input if input_type == selected_input_type)]
              doc.input(placeholder: 'OS grid reference(s)', **(input_type == selected_input_type ? { value: position_input, required: true } : { tabindex: -1 }))
            end
          end
        end
        # TODO: replace the location pickers with this
        # doc.div do
        #   doc.textarea(position_input.gsub(',', "\n"),
        #                rows: 3, cols: 16,
        #                pattern: '([A-Z]{2}\s*(\d{2}\s*\d{2}|\d{3}\s*\d{3}|\d{4}\s*\d{4}|\d{5}\s*\d{5})(\n|$))+')
        # end
        doc.div(class: 'flex-together') do
          [[:grid_north, 'Use grid north'], [:grid_lines, 'Overlay grid lines']].each do |(name, desc)|
            doc.label do
              doc.span(desc)
              doc.select(name: name) do
                [['Map default', ''], %w[Yes true], %w[No false]].each do |(text, value)|
                  option[text, value, raw_req[name] || '', autocomplete: :off]
                end
              end
            end
          end
        end
        doc.div(class: 'flex-together') do
          doc.label do
            doc.span 'Paper size'
            doc.select(name: :paper) do
              PAPER_SIZES.each { |id, paper| option[paper.name, id, page_setup.paper.id] }
            end
          end
          doc.label do
            doc.span 'Margin (cm)'
            doc.input(name: :margin, value: page_setup.page_margin,
                      type: :number, min: 0, max: 10, step: 0.1,
                      style: 'width: 4em')
          end
        end
        doc.div do
          doc.button('Go', type: :submit)
        end
      end
    end
  end.to_html
end

def web_response(centers, partial, tile_server, page_setup, raw_req, coordinate_system, xcount = 0, ycount = 0)
  res = StringIO.new

  unless partial
    res << '<html>'
    res << web_head(page_setup) unless partial
    res << '<body>'
    res << controls(tile_server, page_setup, raw_req)
  end
  centers.each_with_index do |center, i|
    res << web_response_single(center, tile_server, page_setup, minimap(page_setup, centers, i, coordinate_system, xcount, ycount))
  end
  res << '</body></html>' unless partial
  res.string
end

def parse_boolean(string, fallback)
  case string
  when /true/i then true
  when /false/i then false
  else fallback
  end
end

config = parse_config

begin
  rc = YAML.load_file(config[:rc_file], permitted_classes: [Symbol, Range])
rescue Errno::ENOENT
  abort("Cannot find config file #{config[:rc_file].inspect}, have you tried copying the sample one?")
end

$tile_servers = hash_by(
  *rc.filter_map do |server|
    server.transform_keys!(&:to_sym)
    server_type = {
      'zxy' => ZXYTileServer,
      'tms' => TmsTileServer,
      'streetmap' => StreetMapTileServer,
      'quadkey' => QuadkeyTileServer
    }[server[:type]]
    if server_type.nil?
      warn "Unknown server type #{server[:type].inspect}"
      next
    end
    server.delete(:type)
    server_type.new(**server)
  end
)

# Run a cleanup job every 5 minutes
Thread.new do
  loop do
    $tile_servers.each_value do |tile_server|
      next unless Dir.exist? tile_server.folder
      Dir.chdir(tile_server.folder) do
        remaining_space = tile_server.cache_size
        Dir['*'].sort_by { |f| File.mtime(f) }.reverse_each do |f|
          remaining_space -= File.size(f) unless remaining_space < 0
          if remaining_space < 0
            puts "Cleaning up #{tile_server.folder}/#{f}"
            File.delete(f)
          end
        end
      end
    end
    sleep(5*60)
  end 
end

if $stdout.isatty && ARGV[0]
  terminal_response(ARGV.join(' '), $tile_servers.default)
else
  dev_stdout = WEBrick::Log.new(STDOUT, WEBrick::BasicLog::ERROR)
  server = WEBrick::HTTPServer.new(BindAddress: config[:address], Port: config[:port], Logger: dev_stdout, AccessLog: [])
  trap 'TERM' do server.shutdown end
  trap 'INT' do server.shutdown end

  server.mount_proc '/' do |req, res|
    case req.path
    when %r{^/tile/([-\w]+)/(.+)$}
      id = $1
      tile = $2
      tile_server = $tile_servers[id]
      folder = File.join(File.dirname(__FILE__), tile_server.folder)

      FileUtils.mkdir_p(folder)
      cache_path = File.join(folder, tile_server.path_to_tile(tile))
      catch :not_found do
        unless File.exist?(cache_path)
          throw :not_found if config[:offline]
          puts "Fetching #{tile} from #{tile_server.url_to_tile(tile)}"
          begin
            tempfile = Down.download(tile_server.url_to_tile(tile), ssl_verify_mode: OpenSSL::SSL::VERIFY_NONE)
            FileUtils.mv(tempfile.path, cache_path)
          rescue StandardError => e
            puts "Unable to fetch #{tile} from #{tile_server.url_to_tile(tile)}, because #{e.inspect}."
            res.status = 404
            res.body = ''
            throw :not_found
          end
        end
        res.header['Content-Type'] = tile_server.mime
        res.header['Cache-Control'] = 'public'
        res.header['Expires'] = 'never'
        FileUtils.touch cache_path
        res.body = File.new(cache_path, 'r')
      end
    when %r{^/(atlas\.js|atlas\.css)$}
      file_name = $1
      res.header['Content-Type'] = MIME::Types.of(file_name).first
      res.body = File.new(file_name, 'r')
    when '/'
      partial = req.query['partial']
      tile_server = $tile_servers[req.query['style']].with_zoom(req.query['zoom'])
      paper = PAPER_SIZES[req.query['paper']]

      margin = req.query['margin'] ? req.query['margin'].to_f : 0.5
      scale = req.query['scale'] ? req.query['scale'].to_f : 4
      padding = req.query['padding'] ? req.query['padding'].to_f : 0

      coordinate_system = OSGrid.new

      grid_north = parse_boolean(req.query['grid_north'], tile_server.grid_north)
      grid_lines = parse_boolean(req.query['grid_lines'], tile_server.grid_lines)

      page_setup = PageSetup.new(paper, scale, margin, grid_north, grid_lines)

      raw_req = req.query.transform_keys(&:to_sym)
      if req.query['fit']
        fit_points = req.query['fit'].split(',')
        centerRefs, xcount, ycount = calculate_centers(fit_points, padding, page_setup)
        centers = centerRefs.map(&coordinate_system.method(:to_ll))
      elsif req.query['center']
        centers = req.query['center'].split(',').map(&coordinate_system.method(:to_ll))
        xcount = 0
        ycount = 0
      else
        res.status = 400
        centers = []
      end
      res.header['Content-Type'] = 'text/html; charset=utf-8'
      res.body = web_response(centers, !!partial, tile_server, page_setup, raw_req, coordinate_system, xcount, ycount)
    else
      res.status = 400
      res.body = 'Bad URL'
    end
  end

  server.start
end
