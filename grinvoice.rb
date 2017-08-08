require 'json'
require 'csv'
require 'date'


if ARGV.length != 1
  puts('usage: ruby parse-bill.rb file.ocr')
  exit 1
end
file = ARGV.first

class AnnotationsFactory
  def initialize(bill_json)
    @bill_json = bill_json
  end
  
  def create_annotations
    WrittenDateMerger.new.merge(
      DateMerger.new.merge(
        DecimalNumberMerger.new.merge(
          annotations_json.map do |annotation|
            Annotation.new(
              annotation['description'],
              BoundsFactory.new(annotation['boundingPoly']).create_bounds
            )
          end
        )
      )
    )
  end
  
  private
  
  def annotations_json
    responses = @bill_json['responses']
    response = responses.first if responses
    text_annotations = response['textAnnotations'] if response
    text_annotations || []
  end
end

class BoundsFactory
  def initialize(bounds_json)
    @bounds_json = bounds_json
  end
  
  def create_bounds
    Bounds.new(top_left, top_right, bottom_right, bottom_left)
  end
  
  private
  
  def top_left
    create_point(vertices[0])
  end
  
  def top_right
    create_point(vertices[1])
  end
  
  def bottom_right
    create_point(vertices[2])
  end
  
  def bottom_left
    create_point(vertices[3])
  end
  
  def vertices
    @bounds_json['vertices']
  end
  
  def create_point(vertex)
    Point.new(vertex['x'], vertex['y'])
  end
end

class Annotation
  attr_reader :description, :bounds
  
  def initialize(description, bounds)
    @description = description
    @bounds = bounds
  end
  
  def to_s
    "#{@description} (#{@bounds.center})"
  end
end

class AnnotationMerger
  def initialize(annotations, separator = '')
    @annotations = annotations
    @separator = separator
  end
  
  def merged
    Annotation.new(
      @annotations.map(&:description).join(@separator),
      Bounds.new(top_left, top_right, bottom_right, bottom_left))
  end
  
  private
  
  def top_left
    Point.new(
      (@annotations.map { |annotation| annotation.bounds.top_left.x}).min,
      (@annotations.map { |annotation| annotation.bounds.top_left.y}).min)
  end
  
  def top_right
    Point.new(
      (@annotations.map { |annotation| annotation.bounds.top_right.x}).max,
      (@annotations.map { |annotation| annotation.bounds.top_right.y}).min)
  end
  
  def bottom_right
    Point.new(
      (@annotations.map { |annotation| annotation.bounds.bottom_right.x}).max,
      (@annotations.map { |annotation| annotation.bounds.bottom_right.y}).max)
  end
  
  def bottom_left
    Point.new(
      (@annotations.map { |annotation| annotation.bounds.bottom_left.x}).min,
      (@annotations.map { |annotation| annotation.bounds.bottom_left.y}).max)
  end
end

class Bounds
  attr_reader :top_left, :top_right, :bottom_right, :bottom_left

  def initialize(top_left, top_right, bottom_right, bottom_left)
    @top_left = top_left
    @top_right = top_right
    @bottom_right = bottom_right
    @bottom_left = bottom_left
  end
  
  def width
    @top_right.x - @top_left.x
  end
  
  def height
    @bottom_left.y - @top_left.y
  end
  
  def center
    Point.new(@top_left.x + (width / 2.0), @top_left.y + (height / 2.0))
  end
end

class Point
  attr_reader :x, :y
  
  def initialize(x, y)
    @x = x
    @y = y
  end
  
  def distance(point)
    Math.sqrt(((point.x - @x) ** 2) + ((point.y - @y) ** 2))
  end
  
  def to_s
    "#{@x},#{@y}"
  end
end

class Tracer
  def initialize(io)
    @io = io
    @scope_level = 0
  end
  
  def trace(message, inputs = nil, &block)
    if inputs
      print("#{message}: #{summarize(inputs)}")
    else
      print(message)
    end
    
    enter_scope
    results = block.call if block_given?
    exit_scope
    
    print("#{message} results: #{summarize(results)}")
    results
  end
  
  private
  
  def summarize(results)
    results = if results.nil?
      []
    elsif !results.is_a?(Array)
      [results]
    else
      results
    end
      
    results.map(&:to_s).join(', ')
  end
  
  def print(message)
    @io.puts("#{indentation}#{message}\n")
  end
  
  def indentation
    ' ' * (@scope_level * 2)
  end
  
  def enter_scope
    @scope_level += 1
  end
  
  def exit_scope
    @scope_level -= 1
  end
end

class DecimalNumberStateMachine  
  def initialize
    @result = []
    reset
  end
  
  def process(annotation)
    @segments << annotation
    
    if @state == :start
      process_start(annotation)
    elsif @state == :left_number
      process_left_number(annotation)
    elsif @state == :comma
      process_comma(annotation)
    elsif @state == :decimal
      process_decimal(annotation)
    end
  end
  
  def finish
    reset
    @result
  end
  
  private
  
  def process_start(annotation)
    if number?(annotation)
      @state = :left_number
    else
      reset
    end
  end
  
  def process_left_number(annotation)
    if decimal?(annotation)
      @state = :decimal
    elsif comma?(annotation)
      @state = :comma
    else
      reset
    end
  end
  
  def process_decimal(annotation)
    if number?(annotation)
      @segments = [AnnotationMerger.new(@segments).merged]
    end
    
    reset
  end
  
  def process_comma(annotation)
    if number?(annotation)
      @state = :left_number
    else
      reset
    end
  end
  
  def reset
    @state = :start
    @result.push(*@segments)
    @segments = []
  end
  
  def number?(annotation)
    annotation.description =~ /\d+/
  end
  
  def decimal?(annotation)
    annotation.description == '.'
  end
  
  def comma?(annotation)
    annotation.description == ','
  end
end

class DecimalNumberMerger  
  def merge(annotations)
    state_machine = DecimalNumberStateMachine.new
    
    annotations.each do |annotation|
      state_machine.process(annotation)
    end
    state_machine.finish
  end
end

module TotalPaymentAmount
  class LookToTheRightComposerStrategy
    def initialize(tracer)
      @tracer = tracer
    end
    
    def find(annotations)
      ['due', 'total', 'balance'].each do |reference_word|
        total_payment_amount = LookToTheRightStrategy
          .new(@tracer, reference_word)
          .find(annotations)
          
        return total_payment_amount if total_payment_amount 
      end
      
      return nil
    end
  end
  
  class LookToTheRightStrategy
    def initialize(tracer, reference_word)
      @tracer = tracer
      @reference_word = reference_word.downcase
    end
  
    def find(annotations)    
      largest_total_payment_amount(annotations)
    end  
  
    private
  
    def largest_total_payment_amount(annotations)
      @tracer.trace('Finding largest total payment amount') do
        all_total_payment_amounts(annotations).max_by do |annotation|
          annotation.description.to_f
        end
      end
    end
  
    def all_total_payment_amounts(annotations)
      @tracer.trace('Finding all total payment amounts') do
        total_payment_labels(annotations).map do |label|
          first_to_the_right_of(
            label,
            all_horizontally_aligned_with(
              label,
              decimal_numbers(annotations)))
        end.compact
      end
    end
  
    def total_payment_labels(annotations)
      @tracer.trace('Finding all total payment labels') do
        annotations.select do |annotation|
          annotation.description.downcase == @reference_word
        end
      end
    end
  
    def all_horizontally_aligned_with(reference, annotations)
      @tracer.trace('Finding all horizontally aligned with', [reference]) do
        annotations.select { |annotation| horizontally_aligned?(reference, annotation) }
      end
    end
  
    def first_to_the_right_of(reference, annotations)
      @tracer.trace('Finding the first annotation to the right of', [reference]) do
        sort_horizontally(annotations) do
          all_to_the_right_of(reference, annotations)
        end.first
      end
    end
  
    def all_to_the_right_of(reference, annotations)
      @tracer.trace('Finding all annotations to the right of', [reference]) do
        annotations.select do |annotation|
          annotation.bounds.top_left.x >= reference.bounds.top_right.x
        end
      end
    end
  
    def decimal_numbers(annotations)
      @tracer.trace('Finding decimal numbers') do
        annotations.select do |annotation|
          annotation.description =~ /\A\d+,?\d*\.\d\d\z/ ? annotation : nil
        end
      end
    end
  
    def horizontally_aligned?(annotation_1, annotation_2)
      (annotation_1.bounds.top_left.y >= annotation_2.bounds.top_left.y &&
        annotation_1.bounds.top_left.y <= annotation_2.bounds.bottom_left.y) ||
      (annotation_2.bounds.top_left.y >= annotation_1.bounds.top_left.y &&
        annotation_2.bounds.top_left.y <= annotation_1.bounds.bottom_left.y)  
    end
  
    def sort_horizontally(annotations)
      annotations.sort do |annotation_1, annotation_2|
        annotation_1.bounds.top_left.x <=> annotation_2.bounds.top_left.x
      end
    end
  end
end

class DateStateMachine
  def initialize
    @result = []
    @current_separator = nil
    reset
  end
  
  def process(annotation)
    @segments << annotation
    
    if @state == :start
      process_start(annotation)
    elsif @state == :separator_1
      process_separator_1(annotation)
    elsif @state == :month
      process_month(annotation)
    elsif @state == :separator_2
      process_separator_2(annotation)
    elsif @state == :year
      process_year(annotation)
    end
  end
  
  def finish
    reset
    @result
  end
  
  private
  
  def process_start(annotation)
    if number?(annotation)
      @state = :separator_1
    else
      reset
    end
  end
  
  def process_separator_1(annotation)
    if separator?(annotation)
      @state = :month
      @current_separator = annotation.description
    else
      reset
    end
  end
  
  def process_month(annotation)
    if number?(annotation)
      @state = :separator_2
    else
      reset
    end
  end
  
  def process_separator_2(annotation)
    if annotation.description == @current_separator
      @state = :year
    else
      reset
    end
  end
  
  def process_year(annotation)
    if number?(annotation)
      segments = @segments.map { |segment| convert_o_to_zero(segment) }
      @segments = [AnnotationMerger.new(segments).merged]
    end
    
    reset
  end
  
  def reset
    @state = :start
    @current_separator = nil
    @result.push(*@segments)
    @segments = []
  end
  
  def number?(annotation)
    annotation.description =~ /\AO?\d+\Z/
  end
  
  def separator?(annotation)
    annotation.description =~ /\A(,|\.|-|\/)\Z/
  end
  
  def convert_o_to_zero(annotation)
    Annotation.new(
      annotation.description.gsub('O', '0'),
      annotation.bounds
    )
  end
end

class DateMerger  
  def merge(annotations)
    state_machine = DateStateMachine.new
    
    annotations.each do |annotation|
      state_machine.process(annotation)
    end
    state_machine.finish
  end
end

class WrittenDateStateMachine
  def initialize
    @result = []
    reset
  end
  
  def process(annotation)
    @segments << annotation
    
    if @state == :start
      process_start(annotation)
    elsif @state == :month
      process_month(annotation)
    elsif @state == :day
      process_day(annotation)
    elsif @state == :comma
      process_comma(annotation)
    elsif @state == :year
      process_year(annotation)
    end
  end
  
  def finish
    reset
    @result
  end
  
  private
  
  def process_start(annotation)
    if month?(annotation)
      @state = :month
    else
      reset
    end
  end
  
  def process_month(annotation)
    if number?(annotation)
      @state = :day
    else
      reset
    end
  end
  
  def process_day(annotation)
    if number?(annotation)
      @state = :year
      process_year(annotation)
    elsif comma?(annotation)
      @state = :year
    else
      reset
    end
  end
  
  def process_comma(annotation)
    if comma?(annotation)
      @state = :year
    else
      reset
    end
  end
  
  def process_year(annotation)
    if number?(annotation)
      @segments = merge_with_spacing(@segments)
    end
    
    reset
  end
  
  def reset
    @state = :start
    @current_separator = nil
    @result.push(*@segments)
    @segments = []
  end
  
  def number?(annotation)
    annotation.description =~ /\AO?\d+\Z/
  end
  
  def comma?(annotation)
    annotation.description == ','
  end
  
  def month?(annotation)
    months.include?(annotation.description.downcase)
  end
  
  def months
    [
      'january',
      'february',
      'march',
      'april',
      'may',
      'june',
      'july',
      'august',
      'september',
      'october',
      'november',
      'december',
      
      'jan',
      'feb',
      'mar',
      'apr',
      'may',
      'jun',
      'jul',
      'aug',
      'sep',
      'oct',
      'nov',
      'dec',
    ]
  end
  
  def merge_with_spacing(segments)
    if comma?(segments[2])
      segments = [segments[0], AnnotationMerger.new([segments[1], segments[2]]).merged, segments[3]]
    end
    
    [AnnotationMerger.new(segments, ' ').merged]
  end
end

class WrittenDateMerger  
  def merge(annotations)
    state_machine = WrittenDateStateMachine.new
    
    annotations.each do |annotation|
      state_machine.process(annotation)
    end
    state_machine.finish
  end
end

module DueDate
  class ClosestToAnnotationCompositeStrategy
    def initialize(tracer, word)
      @tracer = tracer
      @word = word
    end
    
    def find(annotations)
      ClosestToAnnotationStrategy.new(@tracer, labels(@word, annotations).first).find(annotations)
    end
    
    private
    
    def labels(description, annotations)
      annotations.select { |annotation| annotation.description.downcase == description }
    end
  end
  
  class ClosestToAnnotationStrategy  
    def initialize(tracer, reference)
      @tracer = tracer
      @reference = reference
    end
    
    def find(annotations)
      closest(dates(annotations), @reference)
    end
    
    private
    
    def closest(annotations, reference)
      @tracer.trace("Finding closest to #{reference}") do
        distances = annotations.map do |annotation|
          { distance: annotation.bounds.center.distance(reference.bounds.center), annotation: annotation }
        end
      
        if distances
          (distances.min { |d1, d2| d1[:distance] <=> d2[:distance] })[:annotation]
        end
      end
    end
    
    def distance(annotaiton_1, annotation_2)
      annotation_1.bounds.center.distance(annotation_2.bounds.center)
    end
    
    def dates(annotations)
      @tracer.trace('Finding dates') do
        annotations.select { |annotation| date?(annotation) }
      end
    end
    
    def date?(annotation)
      str = annotation.description.downcase
      parse_date(str, '%m-%d-%Y') ||
      parse_date(str, '%m-%d-%y') ||
      parse_date(str, '%m/%d/%Y') ||
      parse_date(str, '%m/%d/%y') ||
      parse_date(annotation.description.capitalize, '%B %d, %Y') ||
      parse_date(annotation.description.capitalize, '%B %d %Y')
    end
    
    def parse_date(string, format)
      begin
        Date.strptime(string, format)
      rescue
        nil
      end
    end
  end
end


annotations = AnnotationsFactory.new(JSON.parse(File.read(file))).create_annotations
annotation = TotalPaymentAmount::LookToTheRightComposerStrategy.new(Tracer.new($stdout)).find(annotations)

annotation = DueDate::ClosestToAnnotationCompositeStrategy.new(Tracer.new($stdout), 'due').find(annotations)
puts "DUE: #{annotation}"

annotation = DueDate::ClosestToAnnotationCompositeStrategy.new(Tracer.new($stdout), 'date').find(annotations)
puts "DATE: #{annotation}"

file =~ /(\d+)_\d+/
csv = "#{$1}.csv"
amount = CSV.read(csv)[1][3]
extracted = annotation ? annotation.description.gsub(' ', '') : ''

puts "image: #{file}"
puts "csv: #{csv}"
puts "amount: #{amount}"
puts "found: #{extracted}"
puts "match: #{amount == extracted}"
puts

