class LoghouseQuery
  module Clickhouse
    class Expression
      attr_reader :value, :operator
      def initialize(expression, operator = nil)
        @any_key    = expression[:any_key]
        @label_key  = expression[:label_key]
        @custom_key = expression[:custom_key]
        @value      = expression[:str_value].to_s.presence || expression[:num_value]
        @operator   = if expression[:not_null]
                        'not_null'
                      elsif expression[:is_null]
                        'is_null'
                      elsif expression[:is_true]
                        'is_true'
                      elsif expression[:is_false]
                        'is_false'
                      else
                        expression[:e_op]
                      end
      end

      def any_key?
        @any_key.present?
      end

      def kubernetes_key?
        !any_key? && !label_key? && LogsTables::KUBERNETES_ATTRIBUTES.keys.include?(key.to_sym)
      end

      def label_key?
        @label_key.present?
      end

      def key
        @label_key || @custom_key
      end

      def to_s
        case operator
        when 'not_null', 'is_null'
          null
        when 'is_true', 'is_false'
          boolean
        when '>', '<', '<=', '>='
          number_comparison
        when '=~'
          string_regex
        when '!~'
          "not(#{string_regex})"
        when '=', '!='
          if (key == 'phone')
            number_comparison
          elsif (value.is_a?(String) || label_key?)
            equation_string
          else
            equation_all
          end
        end
      end

      private

      def null
        "#{'NOT ' if operator == 'not_null'}has(null_fields.names, '#{key}')"
      end

      def boolean
        "has(boolean_fields.names, '#{key}') AND "\
        "boolean_fields.values[indexOf(boolean_fields.names, '#{key}')] = #{operator == 'is_true' ? 1 : 0}"
      end

      def number_comparison
        if (key == 'phone')
          "#{key} #{operator} #{value}"
        elsif any_key?
          "arrayExists(x -> x #{operator} #{value}, number_fields.values)"
        else
          "has(number_fields.names, '#{key}') AND "\
          "number_fields.values[indexOf(number_fields.names, '#{key}')] #{operator} #{value}"
        end
      end

      def string_regex
        val = value.to_s
        val.gsub!(/\//, '')

        if any_key?
          "arrayExists(x -> match(x, '#{val}'), string_fields.values)"
        elsif kubernetes_key?
          "match(#{key}, '#{val}')"
        elsif label_key?
          "has(labels.names, '#{key}') AND "\
          "match(labels.values[indexOf(labels.names, '#{key}')], '#{val}')"
        else
          "has(string_fields.names, '#{key}') AND "\
          "match(string_fields.values[indexOf(string_fields.names, '#{key}')], '#{val}')"
        end
      end

      def equation_string
        val = value.to_s
        if val.include?('%') || val.include?('_')
          if any_key?
            "arrayExists(x -> #{operator == '=' ? 'like' : 'notLike'}(x, '#{val}'), string_fields.values)"
          elsif kubernetes_key?
            "#{operator == '=' ? 'like' : 'notLike'}(#{key}, '#{val}')"
          elsif label_key?
            "has(labels.names, '#{key}') AND "\
            "#{operator == '=' ? 'like' : 'notLike'}(labels.values[indexOf(labels.names, '#{key}')], '#{val}')"
          else
            "has(string_fields.names, '#{key}') AND "\
            "#{operator == '=' ? 'like' : 'notLike'}(string_fields.values[indexOf(string_fields.names, '#{key}')], '#{val}')"
          end
        else
          if any_key?
            "arrayExists(x -> x #{operator} '#{val}', string_fields.values)"
          elsif kubernetes_key?
            "#{key} #{operator} '#{val}'"
          elsif label_key?
            "has(labels.names, '#{key}') AND "\
            "labels.values[indexOf(labels.names, '#{key}')] #{operator} '#{val}'"
          else
            "has(string_fields.names, '#{key}') AND "\
            "string_fields.values[indexOf(string_fields.names, '#{key}')] #{operator} '#{val}'"
          end
        end
      end

      def equation_all
        if any_key?
          "arrayExists(x -> x #{operator} '#{value}', string_fields.values) OR "\
          "arrayExists(x -> x #{operator} #{value}, number_fields.values)"
        elsif kubernetes_key?
          "#{key} #{operator} '#{value}'"
        else
          <<~EOS
            CASE
              WHEN has(string_fields.names, '#{key}')
                THEN string_fields.values[indexOf(string_fields.names, '#{key}')] #{operator} '#{value}'
              WHEN has(number_fields.names, '#{key}')
                THEN number_fields.values[indexOf(number_fields.names, '#{key}')] #{operator} #{value}
              ELSE 0
            END
          EOS
        end
      end
    end
  end
end
