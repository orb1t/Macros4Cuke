# File: macro-step.rb
# Purpose: Implementation of the MacroStep class.

require_relative 'exceptions'
require_relative 'templating/engine'

module Macros4Cuke # Module used as a namespace
# A macro-step object is a Cucumber step that is itself
# an aggregation of lower-level sub-steps.
# When a macro-step is used in a scenario, then its execution is equivalent
# to the execution of its sub-steps.
# A macro-step may have zero or more arguments.
# The actual values bound to these arguments
# are passed to the sub-steps at execution time.
class MacroStep
  # The set of predefined macro argument constant values.
  BuiltinParameters = {
    'quotes' => '"""'
  }.freeze

  # A template engine that expands the sub-steps upon request.
  attr_reader(:renderer)

  # The sentence fragment that defines the syntax of the macro-step
  attr_reader(:phrase)

  # Unique key of the macro as derived from the macro phrase.
  attr_reader(:key)

  # The list of macro arguments that appears in the macro phrase.
  attr_reader(:phrase_args)

  # The list of macro argument names (as appearing in the substeps
  # AND in the macro phrase).
  attr_reader(:args)

  # Constructor.
  # @param aMacroPhrase[String] The text from the macro step definition
  #   that is between the square brackets.
  # @param theSubsteps [String] The source text of the steps to be expanded
  #   upon macro invokation.
  # @param useTable [boolean] A flag indicating whether a data table
  #   must be used to pass actual values.
  def initialize(aMacroPhrase, theSubsteps, useTable)
    @phrase = aMacroPhrase
    @key = self.class.macro_key(aMacroPhrase, useTable, :definition)

    # Retrieve the macro arguments embedded in the phrase.
    @phrase_args = scan_arguments(aMacroPhrase, :definition)
    @renderer = Templating::Engine.new(theSubsteps)
    substeps_vars = renderer.variables


    @args = validate_phrase_args(@phrase_args, substeps_vars)
    @args.concat(substeps_vars)
    @args.uniq!
  end


  # Compute the identifier of the macro from the given macro phrase.
  # A macro phrase is a text that may contain zero or more placeholders.
  # In definition mode, a placeholder is delimited by chevrons <..>.
  # In invokation mode, a value bound to a placeholder is delimited
  # by double quotes.
  # The rule for building the identifying key are:
  # - Leading and trailing space(s) are removed.
  # - Each underscore character is removed.
  # - Every sequence of one or more space(s) is converted into an underscore
  # - Each placeholder (i.e. = delimiters + enclosed text)
  #     is converted into a letter X.
  # - when useTable is true, concatenate: _T
  # @example:
  #   Consider the macro phrase: 'create the following "contactType" contact'
  #   The resulting macro_key is: 'create_the_following_X_contact_T'
  #
  # @param aMacroPhrase [String] The text from the macro step definition
  #   that is between the square brackets.
  # @param useTable [boolean] A flag indicating whether a table
  #  should be used to pass actual values.
  # @param mode [:definition, :invokation]
  # @return [String] the key of the phrase/macro.
  def self.macro_key(aMacroPhrase, useTable, mode)
    stripped_phrase = aMacroPhrase.strip # Remove leading ... trailing space(s)

    # Remove every underscore
    stripped_phrase.delete!('_')

    # Replace all consecutive whitespaces by an underscore
    stripped_phrase.gsub!(/\s+/, '_')


    # Determine the pattern to isolate
    # each argument/parameter with its delimiters
    pattern = case mode
                when :definition
                  /<(?:[^\\<>]|\\.)*>/
                when :invokation
                  /"([^\\"]|\\.)*"/

              end

    # Each text between quotes or chevron is replaced by the letter X
    normalized = stripped_phrase.gsub(pattern, 'X')

    key = normalized + (useTable ? '_T' : '')

    return key
  end


  # Render the steps from the template, given the values
  # taken by the parameters
  # @param aPhrase [String] an instance of the macro phrase.
  # @param rawData [Array or nil] An Array with couples of the form:
  # [macro argument name, a value].
  #   Multiple rows with same argument name are acceptable.
  def expand(aPhrase, rawData)
    params = validate_params(aPhrase, rawData)

    # Add built-in constants if necessary.
    params = BuiltinParameters.merge(params)

    return renderer.render(nil, params)
  end

  private

  # Build a Hash from the given raw data.
  # @param aPhrase [String] an instance of the macro phrase.
  # @param rawData [Array or nil] An Array with coupples of the form:
  # [macro argument name, a value].
  # Multiple rows with same argument name are acceptable.
  def validate_params(aPhrase, rawData)
    macro_parameters = {}

    # Retrieve the value(s) per variable in the phrase.
    quoted_values = scan_arguments(aPhrase, :invokation)
    quoted_values.each_with_index do |val, index|
      macro_parameters[phrase_args[index]] = val
    end

    unless rawData.nil?
      rawData.each do |a_row|
        (a_key, value) = validate_row(a_row, macro_parameters)
        if macro_parameters.include? a_key
          if macro_parameters[a_key].is_a?(Array)
            macro_parameters[a_key] << value
          else
            macro_parameters[a_key] = [macro_parameters[a_key], value]
          end
        else
          macro_parameters[a_key] = value
        end
      end
    end

    return macro_parameters
  end

  # Validate a row from the data table.
  # Return the validated row.
  # @param a_row [Array] A 2-elements Array (i.e. a couple) of the form:
  # [macro argument name, a value].
  # @param params [Hash] The pairs phrase argument name => value
  def validate_row(a_row, params)
    (a_key, value) = a_row
    raise(UnknownArgumentError.new(a_key)) unless args.include? a_key
    if (phrase_args.include? a_key) && (params[a_key] != value)
      raise(AmbiguousArgumentValue.new(a_key, params[a_key], value))
    end

    return a_row
  end


  # Retrieve from the macro phrase, all the text between <..> or double quotes.
  # Returns an array. Each of its elements corresponds to quoted text.
  # Example:
  # aMacroPhrase = 'a "qualifier" text with "quantity" placeholders.'
  # Results in : ["qualifier", "quantity"]
  # [aMacroPhrase] A phrase
  # [mode] one of the following: :definition, :invokation
  def scan_arguments(aMacroPhrase, mode)
    # determine the syntax of the arguments/parameters
    # as a regular expression with one capturing group
    pattern = case mode
                when :definition
                  /<((?:[^\\<>]|\\.)*)>/
                  # /{{{([^}]*)}}}|{{([^}]*)}}/ # Two capturing groups!...
                when :invokation
                  /"((?:[^\\"]|\\.)*)"/
              end
    raw_result = aMacroPhrase.scan(pattern)
    args = raw_result.flatten.compact

    # Replace escaped quotes by quote character.
    args.map! { |arg| arg.sub(/\\"/, '"') } if mode == :invokation

    return args
  end

  # Check for inconsistencies between the argument names
  # in the phrase and the substeps part.
  def validate_phrase_args(thePhraseArgs, substepsVars)
    # Error when the phrase names an argument that never occurs in the substeps
    thePhraseArgs.each do |phrase_arg|
      next if substepsVars.include? phrase_arg
      raise(UselessPhraseArgument.new(phrase_arg))
    end
    # Error when a substep has an argument that never appears in the phrase
    # and the macro-step does not use data table.
    unless use_table?
      substepsVars.each do |substep_arg|
        next if thePhraseArgs.include?(substep_arg) ||
                BuiltinParameters.include?(substep_arg)
        
        raise(UnreachableSubstepArgument.new(substep_arg))
      end
    end

    return thePhraseArgs.dup
  end


  # Return true, if the macro-step requires a data table
  # to pass actual values of the arguments.
  def use_table?()
    return key =~ /_T$/
  end
end # class
end # module

# End of file
