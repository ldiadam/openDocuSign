# frozen_string_literal: true

module Submitters
  class Formula
    Error = Class.new(StandardError)

    EPOCH = Date.new(1970, 1, 1)

    Token = Struct.new(:type, :value)

    class << self
      def evaluate(expression, values, submission)
        new(values, submission).evaluate(expression)
      rescue Error, ZeroDivisionError, TypeError, ArgumentError
        nil
      end

      def evaluate_text(expression, values, submission)
        new(values, submission).evaluate_text(expression)
      rescue Error, ZeroDivisionError, TypeError, ArgumentError
        ''
      end

      def date_to_days(value)
        return if value.blank?
        return today_days if value.to_s == '{{date}}'

        (Date.parse(value.to_s) - EPOCH).to_i
      rescue Date::Error
        nil
      end

      def days_to_date(days)
        return if days.nil? || !days.is_a?(Numeric) || (days.respond_to?(:finite?) && !days.finite?)

        (EPOCH + days.floor).strftime('%Y-%m-%d')
      end

      def today_days(timezone = 'UTC')
        (Time.current.in_time_zone(timezone.presence || 'UTC').to_date - EPOCH).to_i
      rescue StandardError
        (Date.current - EPOCH).to_i
      end
    end

    def initialize(values, submission)
      @values = values || {}
      @submission = submission
      @fields_index = submission&.fields_uuid_index || {}
      @today = self.class.today_days(submission&.account&.timezone)
    end

    def evaluate(expression, depth: 0)
      source = substitute_fields(expression.to_s, depth)

      return if source.strip.empty?

      Evaluator.new(@today).call(Parser.new(Lexer.new(source).tokenize).parse)
    end

    def evaluate_text(expression, depth: 0)
      return '' if depth > 10

      expression.to_s.gsub(/\{\{(.*?)\}\}/) do
        uuid = Regexp.last_match(1).strip
        field = @fields_index[uuid]

        if (formula = field&.dig('preferences', 'formula').presence)
          if field['type'] == 'text'
            self.class.new(@values, @submission).evaluate_text(formula, depth: depth + 1)
          else
            result = @values[uuid].presence || self.class.new(@values, @submission).evaluate(formula, depth: depth + 1)

            field['type'] == 'date' ? date_result(result) : result.to_s
          end
        else
          value = @values[uuid]

          value.is_a?(Array) ? value.join(', ') : value.to_s
        end
      end
    end

    private

    def substitute_fields(expression, depth)
      return '0' if depth > 10

      expression.gsub(/\{\{(.*?)\}\}/) do
        uuid = Regexp.last_match(1).strip

        if uuid == 'date'
          @today.to_s
        elsif @fields_index.key?(uuid)
          resolve_field(uuid, depth)
        else
          '0'
        end
      end
    end

    def resolve_field(uuid, depth)
      field = @fields_index[uuid]
      formula = field&.dig('preferences', 'formula').presence

      return field_literal(uuid) if formula.blank? || field['type'] == 'text'

      value = self.class.new(@values, @submission).evaluate(formula, depth: depth + 1)

      return 'null' if value.nil?

      if field['type'] == 'date'
        value.is_a?(Numeric) ? value.to_s : 'null'
      elsif value.is_a?(Numeric)
        value.to_s
      else
        numeric_literal(value)
      end
    end

    def date_result(value)
      days = value.is_a?(Numeric) ? value : self.class.date_to_days(value)

      self.class.days_to_date(days).to_s
    end

    def field_literal(uuid)
      field = @fields_index[uuid]
      value = @values[uuid]

      case field && field['type']
      when 'date'
        days = self.class.date_to_days(value)

        days.nil? ? 'null' : days.to_s
      when 'checkbox'
        Evaluator.truthy?(value) ? 'true' : 'false'
      else
        numeric_literal(value)
      end
    end

    def numeric_literal(value)
      value = value.compact.first if value.is_a?(Array)

      return '0' if value.blank?
      return value.to_s if value.is_a?(Numeric)
      return value.to_s if value.to_s.match?(/\A-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?\z/)

      '0'
    end

    class Lexer
      def initialize(source)
        @source = source
      end

      def tokenize
        tokens = []
        source = @source

        until source.empty?
          source = source.sub(/\A\s+/, '')

          break if source.empty?

          token, length = next_token(source)

          tokens << token
          source = source[length..] || ''
        end

        tokens << Token.new(:eof, nil)
      end

      private

      def next_token(source)
        case source
        when /\A(\d+(?:\.\d+)?(?:[eE][+-]?\d+)?)/
          [Token.new(:number, $1.match?(/[.eE]/) ? $1.to_f : $1.to_i), $&.length]
        when /\A"([^"]*)"/
          [Token.new(:string, $1), $&.length]
        when /\A'([^']*)'/
          [Token.new(:string, $1), $&.length]
        when /\A(true|false)\b/i
          [Token.new(:boolean, $1.casecmp('true').zero?), $&.length]
        when /\A(null)\b/i
          [Token.new(:null, nil), $&.length]
        when /\A(and|or)(?=\s|\z)/i
          [Token.new(:operator, $1.downcase), $&.length]
        when /\A(<=|>=|!=|<>|==|\|\||&&|<<|>>|=|<|>|\+|-|\*|\/|%|\^|\||&)/
          [Token.new(:operator, $1), $&.length]
        when /\A\(/
          [Token.new(:lparen, '('), 1]
        when /\A\)/
          [Token.new(:rparen, ')'), 1]
        when /\A,/
          [Token.new(:comma, ','), 1]
        when /\A\{/
          [Token.new(:lbracket, '{'), 1]
        when /\A\}/
          [Token.new(:rbracket, '}'), 1]
        when /\A([A-Za-z_]\w*)/
          [Token.new(:identifier, $1), $&.length]
        else
          raise Error, "Unexpected character in formula: #{source[0, 20]}"
        end
      end
    end

    class Parser
      def initialize(tokens)
        @tokens = tokens
        @position = 0
      end

      def parse
        node = parse_or

        raise Error, 'Unexpected token' unless peek.type == :eof

        node
      end

      private

      def peek
        @tokens[@position]
      end

      def advance
        token = @tokens[@position]

        @position += 1

        token
      end

      def operator?(*values)
        peek.type == :operator && values.include?(peek.value)
      end

      def accept_operator(*values)
        return unless operator?(*values)

        advance.value
      end

      def parse_or
        left = parse_and

        while accept_operator('or', '||')
          left = [:binary, 'or', left, parse_and]
        end

        left
      end

      def parse_and
        left = parse_comparison

        while accept_operator('and', '&&')
          left = [:binary, 'and', left, parse_comparison]
        end

        left
      end

      def parse_comparison
        left = parse_additive

        while (operator = accept_operator('=', '==', '!=', '<>', '<', '>', '<=', '>='))
          left = [:binary, operator, left, parse_additive]
        end

        left
      end

      def parse_additive
        left = parse_multiplicative

        while (operator = accept_operator('+', '-', '|', '&', '<<', '>>'))
          left = [:binary, operator, left, parse_multiplicative]
        end

        left
      end

      def parse_multiplicative
        left = parse_unary

        while (operator = accept_operator('*', '/', '%'))
          left = [:binary, operator, left, parse_unary]
        end

        left
      end

      def parse_unary
        if (operator = accept_operator('-', '+'))
          [:unary, operator, parse_unary]
        elsif peek.type == :identifier && peek.value.casecmp('not').zero?
          advance
          [:unary, 'not', parse_unary]
        else
          parse_power
        end
      end

      def parse_power
        left = parse_primary

        if accept_operator('^')
          [:binary, '^', left, parse_unary]
        else
          left
        end
      end

      def parse_primary
        case peek.type
        when :number, :string, :boolean
          [:literal, advance.value]
        when :null
          advance
          [:literal, nil]
        when :identifier
          name = advance.value

          raise Error, "Unexpected identifier: #{name}" unless peek.type == :lparen

          parse_call(name)
        when :lparen
          advance
          node = parse_or

          raise Error, 'Missing closing parenthesis' unless peek.type == :rparen

          advance
          node
        when :lbracket
          parse_array
        else
          raise Error, "Unexpected token: #{peek.value.inspect}"
        end
      end

      def parse_call(name)
        advance

        arguments = []

        unless peek.type == :rparen
          loop do
            arguments << parse_or

            break unless peek.type == :comma

            advance
          end
        end

        raise Error, 'Missing closing parenthesis' unless peek.type == :rparen

        advance

        [:call, name.downcase, arguments]
      end

      def parse_array
        advance

        items = []

        unless peek.type == :rbracket
          loop do
            items << parse_or

            break unless peek.type == :comma

            advance
          end
        end

        raise Error, 'Missing closing bracket' unless peek.type == :rbracket

        advance

        [:array, items]
      end
    end

    class Evaluator
      def self.truthy?(value)
        case value
        when nil, false then false
        when Numeric then !value.zero?
        when String then !value.empty?
        else true
        end
      end

      def initialize(today)
        @today = today
      end

      def call(node)
        type = node[0]

        case type
        when :literal then node[1]
        when :array then node[1].map { |item| call(item) }
        when :unary then evaluate_unary(node[1], node[2])
        when :binary then evaluate_binary(node[1], node[2], node[3])
        when :call then evaluate_call(node[1], node[2])
        end
      end

      private

      def evaluate_unary(operator, node)
        value = call(node)

        case operator
        when '-' then -to_number(value)
        when '+' then to_number(value)
        when 'not' then !self.class.truthy?(value)
        end
      end

      def evaluate_binary(operator, left_node, right_node)
        case operator
        when 'and'
          self.class.truthy?(call(left_node)) && self.class.truthy?(call(right_node))
        when 'or'
          self.class.truthy?(call(left_node)) || self.class.truthy?(call(right_node))
        else
          left = call(left_node)
          right = call(right_node)

          evaluate_operation(operator, left, right)
        end
      end

      def evaluate_operation(operator, left, right)
        case operator
        when '+' then add(left, right)
        when '-' then to_number(left) - to_number(right)
        when '*' then to_number(left) * to_number(right)
        when '/' then divide(left, right)
        when '%' then modulo(left, right)
        when '^' then to_number(left)**to_number(right)
        when '|' then to_number(left).to_i | to_number(right).to_i
        when '&' then to_number(left).to_i & to_number(right).to_i
        when '<<' then to_number(left).to_i << to_number(right).to_i
        when '>>' then to_number(left).to_i >> to_number(right).to_i
        when '=', '==' then compare_cast(left) == compare_cast(right)
        when '!=', '<>' then compare_cast(left) != compare_cast(right)
        when '<' then compare(left, right) { |l, r| l < r }
        when '>' then compare(left, right) { |l, r| l > r }
        when '<=' then compare(left, right) { |l, r| l <= r }
        when '>=' then compare(left, right) { |l, r| l >= r }
        else
          raise Error, "Unknown operator: #{operator}"
        end
      end

      def evaluate_call(name, argument_nodes)
        if name == 'if'
          raise Error, 'if() expects 3 arguments' unless argument_nodes.size == 3

          return self.class.truthy?(call(argument_nodes[0])) ? call(argument_nodes[1]) : call(argument_nodes[2])
        end

        arguments = argument_nodes.map { |node| call(node) }

        call_function(name, arguments)
      end

      def call_function(name, arguments)
        case name
        when 'abs' then to_number(arguments[0]).abs
        when 'min' then numbers(arguments).min
        when 'max' then numbers(arguments).max
        when 'sum' then numbers(arguments).sum
        when 'avg' then average(numbers(arguments))
        when 'count' then arguments[0].is_a?(Array) ? arguments[0].size : (arguments[0].nil? ? 0 : 1)
        when 'round' then round(arguments[0], arguments[1])
        when 'roundup' then round_up(arguments[0], arguments[1])
        when 'rounddown' then round_down(arguments[0], arguments[1])
        when 'sqrt' then Math.sqrt(to_number(arguments[0]))
        when 'cbrt' then Math.cbrt(to_number(arguments[0]))
        when 'sin' then Math.sin(to_number(arguments[0]))
        when 'cos' then Math.cos(to_number(arguments[0]))
        when 'tan' then Math.tan(to_number(arguments[0]))
        when 'asin' then Math.asin(to_number(arguments[0]))
        when 'acos' then Math.acos(to_number(arguments[0]))
        when 'atan' then Math.atan(to_number(arguments[0]))
        when 'atan2' then Math.atan2(to_number(arguments[0]), to_number(arguments[1]))
        when 'sinh' then Math.sinh(to_number(arguments[0]))
        when 'cosh' then Math.cosh(to_number(arguments[0]))
        when 'tanh' then Math.tanh(to_number(arguments[0]))
        when 'exp' then Math.exp(to_number(arguments[0]))
        when 'log' then Math.log(to_number(arguments[0]))
        when 'log2' then Math.log2(to_number(arguments[0]))
        when 'log10' then Math.log10(to_number(arguments[0]))
        when 'floor' then to_number(arguments[0]).floor
        when 'ceil' then to_number(arguments[0]).ceil
        when 'hypot' then Math.sqrt(numbers(arguments).sum { |number| number * number })
        when 'pow' then to_number(arguments[0])**to_number(arguments[1])
        when 'pi' then Math::PI
        when 'e' then Math::E
        when 'not' then !self.class.truthy?(arguments[0])
        when 'and' then arguments.all? { |argument| self.class.truthy?(argument) }
        when 'or' then arguments.any? { |argument| self.class.truthy?(argument) }
        when 'xor' then arguments.reduce(false) { |acc, argument| acc != self.class.truthy?(argument) }
        when 'length' then arguments[0].nil? ? 0 : arguments[0].to_s.length
        when 'upcase' then arguments[0].to_s.upcase
        when 'downcase' then arguments[0].to_s.downcase
        when 'concat' then arguments.map(&:to_s).join
        when 'left' then arguments[0].to_s[0, to_number(arguments[1]).to_i].to_s
        when 'right' then right(arguments[0], arguments[1])
        when 'mid' then mid(arguments[0], arguments[1], arguments[2])
        when 'trim' then arguments[0].to_s.strip
        when 'contains' then contains(arguments[0], arguments[1])
        when 'today' then @today
        when 'datedif' then datedif(arguments[0], arguments[1], arguments[2])
        else
          raise Error, "Unknown function: #{name}"
        end
      end

      def add(left, right)
        if left.is_a?(String) || right.is_a?(String)
          "#{left}#{right}"
        else
          to_number(left) + to_number(right)
        end
      end

      def divide(left, right)
        divisor = to_number(right)

        raise ZeroDivisionError if divisor.zero?

        to_number(left).to_f / divisor
      end

      def modulo(left, right)
        divisor = to_number(right)

        raise ZeroDivisionError if divisor.zero?

        to_number(left) % divisor
      end

      def compare(left, right)
        left = compare_cast(left)
        right = compare_cast(right)

        yield(left, right)
      rescue ArgumentError, NoMethodError
        false
      end

      def compare_cast(value)
        return value.to_f if value.is_a?(String) && value.match?(/\A-?\d*\.?\d+\z/)

        value
      end

      def to_number(value)
        case value
        when Numeric then value
        when true then 1
        when false then 0
        when String
          raise Error, 'Empty string is not a number' if value.empty?

          Float(value)
        else
          raise Error, "#{value.inspect} is not a number"
        end
      end

      def numbers(arguments)
        flatten(arguments).map { |value| to_number(value) }
      end

      def flatten(values)
        values.each_with_object([]) do |value, acc|
          if value.is_a?(Array)
            acc.push(*flatten(value))
          else
            acc << value
          end
        end
      end

      def average(values)
        return 0 if values.empty?

        values.sum / values.size.to_f
      end

      def round(value, precision = nil)
        value = to_number(value)
        factor = 10.0**to_number(precision || 0)

        ((value * factor) + 0.5).floor / factor
      end

      def round_up(value, precision = nil)
        value = to_number(value)
        factor = 10.0**to_number(precision || 0)

        (value.negative? ? -((-value * factor).floor) : (value * factor).ceil) / factor
      end

      def round_down(value, precision = nil)
        value = to_number(value)
        factor = 10.0**to_number(precision || 0)

        (value.negative? ? -((-value * factor).ceil) : (value * factor).floor) / factor
      end

      def right(value, count)
        count = to_number(count).to_i

        return '' if count.zero?

        value.to_s[-count..].to_s
      end

      def mid(value, start, length)
        string = value.to_s
        start = to_number(start).to_i - 1
        length = to_number(length).to_i

        start.negative? ? '' : string[start, length].to_s
      end

      def contains(value, term)
        if value.is_a?(Array)
          value.include?(term)
        else
          value.to_s.include?(term.to_s)
        end
      end

      def datedif(start_value, end_value, unit)
        return if start_value.nil? || end_value.nil?

        start_days = to_number(start_value)
        end_days = to_number(end_value)
        unit = unit.to_s.downcase

        return end_days - start_days if unit == 'd'

        from = Formula::EPOCH + [start_days, end_days].min.floor
        to = Formula::EPOCH + [start_days, end_days].max.floor

        months = (to.year - from.year) * 12 + to.month - from.month
        months -= 1 if to.day < from.day

        sign = end_days < start_days ? -1 : 1

        case unit
        when 'm' then sign * months
        when 'y' then sign * (months / 12)
        end
      end
    end
  end
end
