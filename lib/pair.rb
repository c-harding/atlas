require 'attr_extras'

class Pair
  def initialize(x_or_pair, y = nil)
    if y.nil?
      @x, @y = x_or_pair
    else
      @x = x_or_pair
      @y = y
    end
  end

  attr_reader :x, :y

  private def split(arg)
    return arg.to_ary if arg.respond_to?(:to_ary)

    [arg, arg]
  end

  private def product(*enums)
    return enum_for(:product, *enums) unless block_given?

    return yield if enums.empty?

    enum, *enums = enums
    enum.each do |value|
      product(*enums) do |*values|
        yield value, *values
      end
    end
  end

  protected def make(*args)
    Pair[*args]
  end

  # Perform these operations pointwise, duplicating any non-pair arguments
  %i[+ - * / -@ +@ % ==].each do |method|
    define_method(method) do |*args|
      xs, ys = args.map(&method(:split)).transpose
      make(x.send(method, *xs), y.send(method, *ys))
    end
  end

  # Perform these operations pointwise, passing arguments literally
  %i[floor ceil round].each do |method|
    define_method(method) do |*args|
      make(x.send(method, *args), y.send(method, *args))
    end
  end

  def map(&block)
    return enum_for(:map) unless block_given?

    make(block[x], block[y])
  end

  def to_ary
    [x, y]
  end
  alias to_a to_ary

  def gradient
    y * 1.0 / x
  end

  def angle
    Math.atan2(y, x)
  end

  def angle_from_vertical
    Math.atan2(x, y)
  end

  def each_xy(exclusive: false, &block)
    product(Range.new(0, x, exclusive), Range.new(0, y, exclusive), &block)
  end

  def each_yx(exclusive: false, &block)
    product(Range.new(0, y, exclusive), Range.new(0, x, exclusive), &block)
  end

  def as_linear_combination(horizontal, vertical)
    h = horizontal
    v = vertical
    # new_x * h + new_y * v == self
    # [[ h.x, v.x ], × [ new_x,  = [ x,
    #  [ h.y, v.y ]] ×   new_y ] =   y ]
    # HV × new = self
    # new = HV⁻¹ × self
    hv_det = 1.0 / (h.x * v.y - h.y * v.x)
    # HV⁻¹ = HV_det * [[  v.y, -v.x ],
    #                  [ -h.y,  h.x ]]
    # HV⁻¹ = HV_det * [[  v.y, -v.x ], * [ x,
    #                  [ -h.y,  h.x ]]     y ]
    Pair[x * (v.y - h.y), y * (-v.x + h.x)] * hv_det
  end

  class << self
    alias [] new
  end
end

class Dimensions < Pair
  alias width x
  alias height y

  def make(*args)
    Dimensions[*args]
  end
end

class LongLat < Pair
  def initialize(x, y = nil)
    if y.nil? && x.respond_to?(:lat)
      super(
        (x.long if x.respond_to?(:long)) ||
          (x.lon if x.respond_to?(:lon)) ||
          (x.lng if x.respond_to?(:lng)),
        x.lat)
    else
      super(x, y)
    end
  end

  alias lon x
  alias lng x
  alias long x
  alias lat y

  R_EARTH_KM = 6371

  R_EARTH_M = R_EARTH_KM * 1000
  RAD_PER_DEG = Math::PI / 180

  # Distance between to other long_lat in metres
  def distance_to(point)
    # Convert to radians
    self_rad = self * RAD_PER_DEG
    point_rad = point * RAD_PER_DEG

    # Delta of positions
    delta_rad = point_rad - self_rad

    a = Math.sin(delta_rad.lat / 2)**2 + Math.cos(self_rad.lat) * Math.cos(point_rad.lat) * Math.sin(delta_rad.long / 2)**2
    c = 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a))

    R_EARTH_M * c # Delta in metres
  end

  # Move east/west then north/south, in metres
  def move(*delta)
    delta = Pair[*delta].map(&:to_f)
    new_long = long + (delta.x / R_EARTH_M) / RAD_PER_DEG / Math.cos(lat * RAD_PER_DEG)
    new_lat = lat + (delta.y / R_EARTH_M) / RAD_PER_DEG
    make(new_long, new_lat)
  end

  def make(*args)
    LongLat[*args]
  end
end
