# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Submitters::Formula do
  subject(:formula) { described_class.new(values, submission) }

  let(:fields_index) do
    {
      'a' => { 'type' => 'number' },
      'b' => { 'type' => 'number' },
      'start' => { 'type' => 'date' },
      'days' => { 'type' => 'number' },
      'name' => { 'type' => 'text' },
      'total' => { 'type' => 'number', 'preferences' => { 'formula' => '{{a}} + {{b}}' } },
      'due' => { 'type' => 'date', 'preferences' => { 'formula' => '{{start}} + {{days}}' } },
      'summary' => { 'type' => 'text', 'preferences' => { 'formula' => '{{name}}: {{total}}' } }
    }
  end
  let(:submission) do
    instance_double(Submission, fields_uuid_index: fields_index,
                                account: instance_double(Account, timezone: 'UTC'))
  end
  let(:values) { { 'a' => 4, 'b' => 10, 'start' => '2024-01-01', 'days' => 30, 'name' => 'Jane' } }

  it 'evaluates arithmetic with field placeholders' do
    expect(formula.evaluate('{{a}} * {{b}} - 1')).to eq(39)
  end

  it 'performs floating point division' do
    expect(formula.evaluate('{{b}} / {{a}}')).to eq(2.5)
  end

  it 'evaluates nested formula fields' do
    expect(formula.evaluate('{{total}} * 2')).to eq(28)
  end

  it 'evaluates functions and guards' do
    expect(formula.evaluate('round({{b}} / 3, 2)')).to eq(3.33)
    expect(formula.evaluate('if({{a}} == 0, 0, {{b}} / {{a}})')).to eq(2.5)
    expect(formula.evaluate('abs(-5) + max(1, 2, 3)')).to eq(8)
  end

  it 'evaluates date arithmetic as day offsets' do
    expect(described_class.days_to_date(formula.evaluate('{{start}} + {{days}}'))).to eq('2024-01-31')
  end

  it 'interpolates text formulas with nested numeric formulas' do
    expect(formula.evaluate_text('{{name}}: {{total}}')).to eq('Jane: 14')
  end

  it 'returns nil for invalid expressions' do
    expect(described_class.evaluate('{{a}} + unknown_function(1)', values, submission)).to be_nil
  end
end
