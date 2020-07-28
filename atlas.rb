#!/usr/bin/env ruby

require 'os_map_ref'
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
require_relative 'lib/dimensions'

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
    address: ENV['ATLAS_ADDRESS'] || '127.0.0.1',
    offline: !ENV['ATLAS_OFFLINE'].empty?
  }
end

PageSetup = Struct.new(:paper, :scale, :page_margin, :os_north, :grid_lines) do
  def initialize(*)
    super
    @axis = Dimensions[0.75, 0.5]
    @overlap = 2.0 # cm
  end
  attr_reader :axis

  def inner
    paper - 2 * page_margin
  end

  def map
    inner - axis * 2
  end

  def safe_map
    map - @overlap
  end

  def scaled_map
    map / scale
  end

  def scaled_safe_map
    safe_map / scale
  end
end

# Allow splatting hashes
class NilClass
  def to_hash
    {}
  end

  def empty?
    true
  end
end

class TileServer
  def initialize(id:, folder:, title: nil, grid_lines: false, os_north: false, zoom: nil, zooms: nil, scale: 0)
    @id = id
    @folder = folder
    @grid_lines = grid_lines
    @os_north = os_north
    @scale = scale
    @title = title || id
    @zooms = zooms || (zoom.nil? ? 8..16 : [zoom])
    @zoom = closest_zoom(zoom || 14)
  end

  attr_reader :id, :folder, :grid_lines, :os_north, :title, :zoom, :zooms, :scale

  def proxy_to_tile(tile)
    "/tile/#{id}/#{tile}"
  end

  def from_os(easting, northing)
    latitude, longitude = latlong_deg_from_coords(easting, northing)
    from_ll(latitude, longitude)
  end

  def to_os(tile)
    latitude, longitude = to_ll(tile)
    coords_from_latlong_deg(latitude, longitude)
  end

  def coords_from_latlong_deg(lat, _long)
    latlong = OsgbConvert::WGS84.new(lat, lon, 0)
    grid = OsgbConvert::OSGrid.from_wgs84(latlong)
    [grid.easting, grid.northing]
  end

  def latlong_deg_from_coords(easting, northing)
    grid = OsgbConvert::OSGrid.new(easting, northing)
    latlong = grid.wgs84
    [latlong.lat, latlong.long]
  end

  # number of kilometers per tile horizontally
  def scale_factor_at(center)
    easting, northing = coords_for_ref(center)
    tile = from_os(easting, northing)

    square_left = latlong_deg_from_coords(easting.floor(-3), northing)
    square_right = latlong_deg_from_coords(easting.floor(-3) + 1000, northing)
    tile_left = to_ll(tile)
    tile_right = to_ll(move(tile, 1, 0))

    pythagoras(distance(tile_left, tile_right)[0..1]) / pythagoras(distance(square_left, square_right))
  end

  def proportion(tile, (easting, northing))
    tl_latitude, tl_longitude = to_ll(tile)
    br_latitude, br_longitude = to_ll(move(tile, 1, 1))

    latitude, longitude = latlong_deg_from_coords(easting, northing)

    [(longitude - tl_longitude) / (br_longitude - tl_longitude), (latitude - tl_latitude) / (br_latitude - tl_latitude)]
  end

  def distance(p1, p2)
    p1.zip(p2).map { |(a, b)| a - b }
  end

  def pythagoras(as)
    as.map { |a| a**2 }.reduce(:+)**0.5
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
    QuadkeyTileServer.new(url: @url, id: id, folder: @folder, zoom: zoom, zooms: @zooms, grid_lines: grid_lines, os_north: os_north)
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

  def from_ll(lat, long)
    Quadkey.encode(lat, long, @zoom)
  end

  def to_ll(q)
    Quadkey.decode(q)
  end
end

class StreetMapTileServer < TileServer
  def initialize(url:, lookup_url:, tile_size:, **rest)
    super(grid_lines: false, os_north: false, **rest)
    @url = url
    @lookup_url = lookup_url
    @mime = 'image/gif'
    @extension = 'gif'
    @tile_size = tile_size
    # @fetch_queue = Buffer.new(4, 0.1)
  end

  attr_reader :mime, :lookup_url, :tile_size

  def joiner
    '-'
  end

  def new_with_zoom(_zoom)
    self
  end

  def fetch(smref)
    @fetch_queue.update { |queue| queue + [smref] }
    sleep
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

  def proportion(smref, (easting, northing))
    bl_easting, bl_northing = to_os(smref)
    tr_easting, tr_northing = to_os(move(smref, 1, -1))
    [
      (easting.to_f - bl_easting) / (tr_easting.to_f - bl_easting),
      # negated because the coordinate system is reversed: low y is south
      1 - (northing.to_f - bl_northing) / (tr_northing.to_f - bl_northing)
    ]
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
end

class ZXYTileServer < TileServer
  def initialize(url:, **rest)
    super(**rest)
    @url = url
    @mime = 'image/jpeg'
    @extension = 'jpg'
  end

  attr_reader :mime

  def new_with_zoom(zoom)
    ZXYTileServer.new(url: @url, id: id, folder: @folder, zoom: zoom, zooms: @zooms, grid_lines: grid_lines, os_north: os_north)
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

  def url_to_tile(zxy)
    z, x, y = split(zxy)
    @url
      .gsub(/\{((?:\w+\|)+\w+)\}/) { Regexp.last_match(1).split('|').sample }
      .gsub(/\{(\w)\}/) { { 'z' => z, 'x' => x, 'y' => y }[Regexp.last_match(1)] }
  end

  def move(zxy, dx, dy)
    z, x, y = split(zxy)
    join(z, x + dx, y + dy)
  end

  def from_ll(lat, long)
    z = @zoom
    lat_rad = lat / 180 * Math::PI
    n = 2.0**z
    x = ((long + 180.0) / 360.0 * n).to_i
    y = ((1.0 - Math.log(Math.tan(lat_rad) + (1 / Math.cos(lat_rad))) / Math::PI) / 2.0 * n).to_i
    join(z, x, y)
  end

  def to_ll(zxy)
    z, x, y = split(zxy)

    n = 2.0**z
    long = x / n * 360.0 - 180.0
    lat_rad = Math.atan(Math.sinh(Math::PI * (1 - 2 * y / n)))
    lat = 180.0 * (lat_rad / Math::PI)
    [lat, long]
  end
end

def terminal_response(center, tile_server)
  Dir.chdir(File.dirname(__FILE__))
  center_tile = tile_server.from_os(*coords_for_ref(center))
  (-$h..$h).each do |y|
    line = (-$w..$w).map do |x|
      tile_server.move(center_tile, x, y)
    end
    system("./imgrow -u #{line.map { |cell| tile_server.url_to_tile(cell).inspect }.join(' ')}")
  end
end

def ref_for_coords(easting, northing)
  OsMapRef::Location.for([
    '%06d' % easting,
    '%06d' % northing
  ].join(',')).map_reference
end

def coords_for_ref(center)
  ref = OsMapRef::Location.for(center)
  [ref.easting.to_i, ref.northing.to_i]
end

# in kilometers
def offset_grid_ref(center, dx, dy)
  easting, northing = coords_for_ref(center)
  ref_for_coords(
    easting + (1000 * dx),
    northing + (1000 * dy)
  )
end

def neighbours(center, w, h)
  up = offset_grid_ref(center, 0, h)
  down = offset_grid_ref(center, 0, -h)
  left = offset_grid_ref(center, -w, 0)
  right = offset_grid_ref(center, w, 0)

  [up, down, left, right]
end

def calculate_centers(points, padding, page_setup)
  easting_limits = points.map { |ref| coords_for_ref(ref)[0] }.minmax
  northing_limits = points.map { |ref| coords_for_ref(ref)[1] }.minmax
  mid = ref_for_coords(easting_limits.reduce(:+) / 2.0, northing_limits.reduce(:+) / 2.0)
  range = Dimensions[
    easting_limits[1] - easting_limits[0], # (m)
    northing_limits[1] - northing_limits[0], # (m)
  ] / 1000.0 + padding # (km)

  counts = (range / page_setup.scaled_safe_map).floor

  min = offset_grid_ref(mid, * -page_setup.scaled_safe_map * counts / 2)

  [counts.each_yx.map do |y, x|
    offset_grid_ref(min, * page_setup.scaled_safe_map * [x, y])
  end.join(','), *(counts + 1)]
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
          --page-margin: #{page_setup.page_margin}cm;
          --page-width: #{page_setup.map.width}cm;
          --page-height: #{page_setup.map.height}cm;
          --easting-axis: #{page_setup.axis.height}cm;
          --northing-axis: #{page_setup.axis.height}cm;
          --page-size: #{page_setup.paper.name};
        }
      </style>
      <link rel="stylesheet" href="atlas.css" />
      <script src="./atlas.js"></script>
    </head>
  )
end

def corner_label(center, dx, dy, page_setup)
  offset_grid_ref(
    center,
    * page_setup.scaled_map * [dx, dy] / 2
  )
end

def web_response_single(center, tile_server, page_setup, minimap = '')
  easting, northing = coords_for_ref(center)

  # normalize input
  center = ref_for_coords(easting, northing)
  centerTile = tile_server.from_os(easting, northing)

  scale_factor = tile_server.scale_factor_at(center)

  skip = case page_setup.scale
         when 1.. then 1
         when 0.5.. then 5
         when (1.0 / 8).. then 10
         else 20
         end

  cell_pos_x, cell_pos_y = tile_server.proportion(centerTile, [easting, northing])

  res = StringIO.new

  up, down, left, right = neighbours(
    center,
    *page_setup.scaled_safe_map
  )

  corner_of_center_square = lambda do |dx, dy|
    tile_server.proportion(centerTile, [
                             ((easting / skip / 1000).floor + dx) * skip * 1000,
                             ((northing / skip / 1000).floor + dy) * skip * 1000
                           ])
  end

  cell_side = corner_of_center_square[0, 0].zip(corner_of_center_square[0, 1]).map { |(a, b)| a - b }
  true_north = Math.atan2(*cell_side)

  res << %(
    <div class="page"
      data-center="#{center}"
      data-easting="#{easting}"
      data-northing="#{northing}"
      data-north="#{up}"
      data-south="#{down}"
      data-west="#{left}"
      data-east="#{right}"
      data-skip="#{skip}"
    >
      <div class="map-frame">
        <style>
          .page[data-center='#{center}'] {
          }

          .page[data-center='#{center}'] table img {
            width: #{page_setup.scale * scale_factor}cm;
            height: #{page_setup.scale * scale_factor}cm;
          }
        </style>
        <div class="grid-letters top left">#{corner_label(center, -1, 1, page_setup)[0..2]}</div>
        <div class="grid-letters bottom left">#{corner_label(center, -1, -1, page_setup)[0..2]}</div>
        <div class="grid-letters top right">#{corner_label(center, 1, 1, page_setup)[0..2]}</div>
        <div class="grid-letters bottom right">#{corner_label(center, 1, -1, page_setup)[0..2]}</div>
        <div class="border vertical pre"></div>
        <div class="border vertical post"></div>
        <div class="border horizontal pre"></div>
        <div class="border horizontal post"></div>
        #{minimap}
        <div class='map'>
          <table
            style="margin-top: #{-page_setup.scale * scale_factor * cell_pos_y}cm;
                    margin-bottom: #{-page_setup.scale * scale_factor * (1 - cell_pos_y)}cm;
                    margin-left: #{-page_setup.scale * scale_factor * cell_pos_x}cm;
                    margin-right: #{-page_setup.scale * scale_factor * (1 - cell_pos_x)}cm;
                    #{page_setup.os_north ? "transform: rotate(#{true_north}rad);" : ''}
                    transform-origin:
                    calc(50% + #{page_setup.scale * cell_pos_x}cm / 2 - #{page_setup.scale * (1 - cell_pos_x)}cm / 2)
                    calc(50% + #{page_setup.scale * cell_pos_y}cm / 2 - #{page_setup.scale * (1 - cell_pos_y)}cm / 2);"
          >
  )
  tile_grid = (page_setup.scaled_map / 2.0 / scale_factor).ceil + 1
  (-tile_grid.height..tile_grid.height).each do |y|
    res << '<tr>'
    (-tile_grid.width..tile_grid.width).each do |x|
      cell = tile_server.move(centerTile, x, y)
      center = y == 0 && x == 0
      res << '<td '
      res << "class='center'" if center
      res << '>'
      if center
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
            style='left: #{cell_pos_x * 100}%; top: #{cell_pos_y * 100}%;'
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

def minimap(page_setup, centers, index, xcount, ycount)
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
      minimap << "data-center='#{centers[i]}' "
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
    input = lambda { |name, value = nil, type: :hidden, autocomplete: :off, **attrs|
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
              option[tile_server.title, tile_server.id, chosen_tile_server.id,
                     'data-zooms': tile_server.zooms.to_a, 'data-scale': tile_server.scale]
            end
          end
          current_zoom = chosen_tile_server.zoom
          doc.label(class: ['zoom-control', *([:hidden] if chosen_tile_server.zooms.size <= 1)].join(' ')) do
            doc.span('Zoom')
            input[:zoom, current_zoom, type: :number,
                                       min: chosen_tile_server.zooms.min || 0,
                                       max: chosen_tile_server.zooms.max || 0,
                                       style: 'width: 4em']
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
              doc.span "#{input_type.to_s.capitalize} "

              input[input_type, (position_input if input_type == selected_input_type)]
              doc.input(**(input_type == selected_input_type ? { value: position_input, required: true } : { tabindex: -1 }))
            end
          end
        end
        doc.div(class: 'flex-together') do
          [[:os_north, 'Use grid north'], [:grid_lines, 'Overlay OS grid lines']].each do |(name, desc)|
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

def web_response(centers, partial, tile_server, page_setup, raw_req, xcount = 0, ycount = 0)
  res = StringIO.new

  unless partial
    res << '<html>'
    res << web_head(page_setup) unless partial
    res << '<body>'
    res << controls(tile_server, page_setup, raw_req)
  end
  centers.each_with_index do |center, i|
    res << web_response_single(center, tile_server, page_setup, minimap(page_setup, centers, i, xcount, ycount))
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
  rc = YAML.load_file(config[:rc_file])
rescue Errno::ENOENT
  abort("Cannot find config file #{config[:rc_file].inspect}, have you tried copying the sample one?")
end

$tile_servers = hash_by(
  *rc.filter_map do |server|
    server.transform_keys!(&:to_sym)
    server_type = {
      'zxy' => ZXYTileServer,
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
      id = Regexp.last_match(1)
      tile = Regexp.last_match(2)
      tile_server = $tile_servers[id]
      folder = File.join(File.dirname(__FILE__), tile_server.folder)

      FileUtils.mkdir_p(folder)
      cache_path = File.join(folder, tile_server.path_to_tile(tile))
      catch :not_found do
        unless File.exist?(cache_path)
          throw :not_found if config[:offline]
          # puts "Fetching #{tile}"
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
        res.body = File.new(cache_path, 'r')
      end
    when %r{^/(atlas\.js|atlas\.css)$}
      file_name = Regexp.last_match(1)
      res.header['Content-Type'] = MIME::Types.of(file_name).first
      res.body = File.new(file_name, 'r')
    when '/'
      centers = req.query['center']
      partial = req.query['partial']
      tile_server = $tile_servers[req.query['style']].with_zoom(req.query['zoom'])
      paper = PAPER_SIZES[req.query['paper']]

      margin = req.query['margin'] ? req.query['margin'].to_f : 0.5
      scale = req.query['scale'] ? req.query['scale'].to_f : 4
      padding = req.query['padding'] ? req.query['padding'].to_f : 0

      os_north = parse_boolean(req.query['os_north'], tile_server.os_north)
      grid_lines = parse_boolean(req.query['grid_lines'], tile_server.grid_lines)

      page_setup = PageSetup.new(paper, scale, margin, os_north, grid_lines)

      raw_req = req.query.transform_keys(&:to_sym)
      if req.query['fit']
        centers, xcount, ycount = calculate_centers(req.query['fit'].split(','), padding, page_setup)
      else
        xcount = 0
        ycount = 0
      end
      if centers
        res.header['Content-Type'] = 'text/html; charset=utf-8'
        res.body = web_response(centers.split(','), !!partial, tile_server, page_setup, raw_req, xcount, ycount)
      else
        res.status = 400
        res.body = 'No center given'
      end
    else
      res.status = 400
      res.body = 'Bad URL'
    end
  end

  server.start
end
