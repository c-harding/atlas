require_relative 'pair'

class OSRef
  class Error < StandardError
  end

  private_class_method def self.parse_letter(letter)
    LETTER_GRID.each_with_index do |row, northing_square|
      easting_square = row.index(letter)
      return Pair[easting_square, northing_square] if easting_square
    end
    nil
  end

  private_class_method def self.parse_myriad(pair)
    (parse_letter(pair[0]) - ORIGIN) * 5 + parse_letter(pair[1])
  end

  private_class_method def self.to_letter(easting, northing)
    LETTER_GRID[northing][easting]
  end

  private_class_method def self.to_myriad(square)
    pentad = square / 5 + ORIGIN
    sub_myriad = square % 5
    to_letter(*pentad) + to_letter(*sub_myriad)
  end

  def self.to_ref(easting, northing)
    myriad = to_myriad(Pair[easting, northing] / GRID_SIZE)

    # Simplify trailing zeroes
    trailing_zeros = (0...GRID_SIZE_LOG10 - 1).reverse_each.find do |n|
      easting % (10**n) === 0 && northing % (10**n) === 0
    end
    precision = 5 - trailing_zeros
    meters = format('%0*d', precision, easting % GRID_SIZE / (10**trailing_zeros)) + format('%0*d', precision, northing % GRID_SIZE / (10**trailing_zeros))

    myriad + meters
  end

  def self.parse_ref(code)
    match = /
    ^
      (?<myriad>[a-z]{2}) # letters
      \s* # space
      (
        (?<combined>\d+) # even number of digits
      |
        (?<northing>\d{,5})\s+(?<easting>\d{,5}) # space-separated digits
      )
      $
    /ix.match(code)
    raise Error, "Invalid grid reference #{code.inspect}" unless match

    myriad = parse_myriad(match[:myriad])
    combined = match[:combined]
    northing = match[:northing] || combined[...combined.size / 2]
    easting = match[:easting] || combined[combined.size / 2...]

    raise Error, "Imbalanced grid reference #{code.inspect}" unless northing.length == easting.length

    (myriad * GRID_SIZE + [northing.ljust(5, '0').to_i, easting.ljust(5, '0').to_i]).to_a
  end

  # Reversed (vertically) because the bottom left is lower
  LETTER_GRID = %w[
    ABCDE
    FGHJK
    LMNOP
    QRSTU
    VWXYZ
  ].reverse.freeze

  ORIGIN = parse_letter('S')

  GRID_SIZE_LOG10 = 5

  GRID_SIZE = 10**GRID_SIZE_LOG10
end
