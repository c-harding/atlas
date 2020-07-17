require 'attr_extras'

class Dimensions
  vattr_initialize :width, :height

  private def split(x)
    return x.to_ary if x.respond_to?(:to_ary)

    [x, x]
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

  # Perform these operations pointwise, duplicating any non-pair arguments
  %i[+ - * / -@ +@].each do |method|
    define_method(method) do |*args|
      xs, ys = args.map(&method(:split)).transpose
      Dimensions[width.send(method, *xs), height.send(method, *ys)]
    end
  end

  # Perform these operations pointwise, passing arguments literally
  %i[floor ceil round].each do |method|
    define_method(method) do |*args|
      Dimensions[width.send(method, *args), height.send(method, *args)]
    end
  end

  def to_ary
    [width, height]
  end
  alias to_a to_ary

  def each_xy(exclusive: false, &block)
    product(Range.new(0, width, exclusive), Range.new(0, height, exclusive), &block)
  end

  def each_yx(exclusive: false, &block)
    product(Range.new(0, height, exclusive), Range.new(0, width, exclusive), &block)
  end

  class << self
    alias [] new
  end
end
