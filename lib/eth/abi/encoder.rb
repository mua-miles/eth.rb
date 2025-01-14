# Copyright (c) 2016-2023 The Ruby-Eth Contributors
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# -*- encoding : ascii-8bit -*-

# Provides the {Eth} module.
module Eth

  # Provides a Ruby implementation of the Ethereum Application Binary Interface (ABI).
  module Abi

    # Provides a utility module to assist encoding ABIs.
    module Encoder
      extend self

      # Encodes a specific value, either static or dynamic.
      #
      # @param type [Eth::Abi::Type] type to be encoded.
      # @param arg [String|Number] value to be encoded.
      # @param packed [Boolean] use custom packed encoding.
      # @return [String] the encoded type.
      # @raise [EncodingError] if value does not match type.
      def type(type, arg, packed = false)
        if %w(string bytes).include? type.base_type and type.sub_type.empty? and type.dimensions.empty?
          raise EncodingError, "Argument must be a String" unless arg.instance_of? String
          # encodes strings and bytes
          size = type(Type.size_type, arg.size, packed)
          padding = Constant::BYTE_ZERO * (Util.ceil32(arg.size) - arg.size)

          return "#{arg}" if packed
          "#{size}#{arg}#{padding}"
        elsif type.base_type == "tuple" && type.dimensions.size == 1 && type.dimensions[0] != 0
          result = ""
          result += struct_offsets(type.nested_sub, arg)
          result += arg.map { |x| type(type.nested_sub, x, packed) }.join
          result
        elsif type.dynamic? && arg.is_a?(Array)
          # encodes dynamic-sized arrays
          head, tail = "", ""
          head += type(Type.size_type, arg.size, packed) unless packed
          nested_sub = type.nested_sub
          nested_sub_size = type.nested_sub.size

          # calculate offsets
          if %w(string bytes).include?(type.base_type) && type.sub_type.empty? && !packed
            offset = 0
            arg.size.times do |i|
              if i == 0
                offset = arg.size * 32
              else
                number_of_words = ((arg[i - 1].size + 32 - 1) / 32).floor
                total_bytes_length = number_of_words * 32
                offset += total_bytes_length + 32
              end

              head += type(Type.size_type, offset, packed)
            end
          elsif nested_sub.base_type == "tuple" && nested_sub.dynamic? && !packed
            head += struct_offsets(nested_sub, arg)
          end

          arg.size.times do |i|
            head += type(nested_sub, arg[i], packed)
          end

          "#{head}#{tail}"
        else
          if type.dimensions.empty?
            # encode a primitive type
            primitive_type type, arg, packed
          else

            # encode static-size arrays
            arg.map { |x| type(type.nested_sub, x, packed) }.join
          end
        end
      end

      # Encodes primitive types.
      #
      # @param type [Eth::Abi::Type] type to be encoded.
      # @param arg [String|Number] value to be encoded.
      # @param packed [Boolean] use custom packed encoding.
      # @return [String] the encoded primitive type.
      # @raise [EncodingError] if value does not match type.
      # @raise [ValueOutOfBounds] if value is out of bounds for type.
      # @raise [EncodingError] if encoding fails for type.
      def primitive_type(type, arg, packed = false)
        case type.base_type
        when "uint"
          uint arg, type, packed
        when "bool"
          bool arg, packed
        when "int"
          int arg, type, packed
        when "ureal", "ufixed" # TODO: Q9F
          ufixed arg, type
        when "real", "fixed" # TODO: Q9F
          fixed arg, type
        when "string", "bytes"
          bytes arg, type, packed
        when "tuple" # TODO: Q9F
          tuple arg, type
        when "hash" # TODO: Q9F
          hash arg, type
        when "address" # TODO: Q9F
          address arg, packed
        else
          raise EncodingError, "Unhandled type: #{type.base_type} #{type.sub_type}"
        end
      end

      private

      # Properly encodes unsigned integers.
      def uint(arg, type, packed)
        raise ArgumentError, "Don't know how to handle this input." unless arg.is_a? Numeric
        raise ValueOutOfBounds, "Number out of range: #{arg}" if arg > Constant::UINT_MAX or arg < Constant::UINT_MIN
        real_size = type.sub_type.to_i
        i = arg.to_i
        raise ValueOutOfBounds, arg unless i >= 0 and i < 2 ** real_size
        if packed
          len = real_size / 8
          return Util.zpad_int(i, len)
        else
          return Util.zpad_int(i)
        end
      end

      # Properly encodes signed integers.
      def int(arg, type, packed)
        raise ArgumentError, "Don't know how to handle this input." unless arg.is_a? Numeric
        raise ValueOutOfBounds, "Number out of range: #{arg}" if arg > Constant::INT_MAX or arg < Constant::INT_MIN
        real_size = type.sub_type.to_i
        i = arg.to_i
        raise ValueOutOfBounds, arg unless i >= -2 ** (real_size - 1) and i < 2 ** (real_size - 1)
        if packed
          len = real_size / 8
          return Util.zpad_int(i % 2 ** type.sub_type.to_i, len)
        else
          return Util.zpad_int(i % 2 ** type.sub_type.to_i)
        end
      end

      # Properly encodes booleans.
      def bool(arg, packed)
        raise EncodingError, "Argument is not bool: #{arg}" unless arg.instance_of? TrueClass or arg.instance_of? FalseClass
        Util.zpad_int(arg ? 1 : 0, packed ? 1 : 32)
      end

      # Properly encodes unsigned fixed-point numbers.
      def ufixed(arg, type)
        raise ArgumentError, "Don't know how to handle this input." unless arg.is_a? Numeric
        high, low = type.sub_type.split("x").map(&:to_i)
        raise ValueOutOfBounds, arg unless arg >= 0 and arg < 2 ** high
        Util.zpad_int((arg * 2 ** low).to_i)
      end

      # Properly encodes signed fixed-point numbers.
      def fixed(arg, type)
        raise ArgumentError, "Don't know how to handle this input." unless arg.is_a? Numeric
        high, low = type.sub_type.split("x").map(&:to_i)
        raise ValueOutOfBounds, arg unless arg >= -2 ** (high - 1) and arg < 2 ** (high - 1)
        i = (arg * 2 ** low).to_i
        Util.zpad_int(i % 2 ** (high + low))
      end

      # Properly encodes byte-strings.
      def bytes(arg, type, packed)
        raise EncodingError, "Expecting String: #{arg}" unless arg.instance_of? String
        arg = handle_hex_string arg, type

        if type.sub_type.empty?
          size = Util.zpad_int arg.size
          padding = Constant::BYTE_ZERO * (Util.ceil32(arg.size) - arg.size)

          pp size, arg, padding if packed

          # variable length string/bytes
          "#{size}#{arg}#{padding}"
        else
          raise ValueOutOfBounds, arg unless arg.size <= type.sub_type.to_i
          padding = Constant::BYTE_ZERO * (32 - arg.size)

          pp arg, padding if packed

          return "#{arg}" if packed

          # fixed length string/bytes
          "#{arg}#{padding}"
        end
      end

      # Properly encodes tuples.
      def tuple(arg, type)
        raise EncodingError, "Expecting Hash: #{arg}" unless arg.instance_of? Hash
        raise EncodingError, "Expecting #{type.components.size} elements: #{arg}" unless arg.size == type.components.size

        static_size = 0
        type.components.each_with_index do |component, i|
          if type.components[i].dynamic?
            static_size += 32
          else
            static_size += Util.ceil32(type.components[i].size || 0)
          end
        end

        dynamic_offset = static_size
        offsets_and_static_values = []
        dynamic_values = []

        type.components.each_with_index do |component, i|
          component_type = type.components[i]
          if component_type.dynamic?
            offsets_and_static_values << type(Type.size_type, dynamic_offset)
            dynamic_value = type(component_type, arg.is_a?(Array) ? arg[i] : arg[component_type.name])
            dynamic_values << dynamic_value
            dynamic_offset += dynamic_value.size
          else
            offsets_and_static_values << type(component_type, arg.is_a?(Array) ? arg[i] : arg[component_type.name])
          end
        end

        offsets_and_static_values.join + dynamic_values.join
      end

      # Properly encode struct offsets.
      def struct_offsets(type, arg)
        result = ""
        offset = arg.size
        tails_encoding = arg.map { |a| type(type, a) }
        arg.size.times do |i|
          if i == 0
            offset *= 32
          else
            offset += tails_encoding[i - 1].size
          end
          offset_string = type(Type.size_type, offset)
          result += offset_string
        end
        result
      end

      # Properly encodes hash-strings.
      def hash(arg, type)
        size = type.sub_type.to_i
        raise EncodingError, "Argument too long: #{arg}" unless size > 0 and size <= 32
        if arg.is_a? Integer

          # hash from integer
          Util.zpad_int arg
        elsif arg.size == size

          # hash from encoded hash
          Util.zpad arg, 32
        elsif arg.size == size * 2

          # hash from hexadecimal hash
          Util.zpad_hex arg
        else
          raise EncodingError, "Could not parse hash: #{arg}"
        end
      end

      # Properly encodes addresses.
      def address(arg, packed)
        if arg.is_a? Address
          # address from eth::address
          if packed
            Util.zpad_hex arg.to_s[2..-1], 20
          else
            Util.zpad_hex arg.to_s
          end
        elsif arg.is_a? Integer
          # address from integer
          if packed
            Util.zpad_int arg, 20
          else
            Util.zpad_int arg
          end
        elsif arg.size == 20
          # address from encoded address
          if packed
            Util.zpad arg, 20
          else
            Util.zpad arg, 32
          end
        elsif arg.size == 40
          # address from hexadecimal address with 0x prefix
          if packed
            Util.zpad_hex arg, 20
          else
            Util.zpad_hex arg
          end
        elsif arg.size == 42 and arg[0, 2] == "0x"
          # address from hexadecimal address
          if packed
            Util.zpad_hex arg[2..-1], 20
          else
            Util.zpad_hex arg[2..-1]
          end
        else
          raise EncodingError, "Could not parse address: #{arg}"
        end
      end

      # The ABI encoder needs to be able to determine between a hex `"123"`
      # and a binary `"123"` string.
      def handle_hex_string(arg, type)
        if Util.prefixed? arg or
           (arg.size === type.sub_type.to_i * 2 and Util.hex? arg)

          # There is no way telling whether a string is hex or binary with certainty
          # in Ruby. Therefore, we assume a `0x` prefix to indicate a hex string.
          # Additionally, if the string size is exactly the double of the expected
          # binary size, we can assume a hex value.
          Util.hex_to_bin arg
        else

          # Everything else will be assumed binary or raw string.
          arg.b
        end
      end
    end
  end
end
