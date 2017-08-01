require 'json'


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
    DecimalNumberMerger.new.merge(
      select_reasonably_sized(
        annotations_json.map do |annotation|
          Annotation.new(
            annotation['description'],
            BoundsFactory.new(annotation['boundingPoly']).create_bounds
          )
        end
      )
    )
  end
  
  private
  
  def select_reasonably_sized(annotations)
    annotations.select do |annotation|
      annotation.bounds.width <= reasonable_width &&
      annotation.bounds.height <= reasonable_height
    end
  end
  
  def annotations_json
    responses = @bill_json['responses']
    response = responses.first if responses
    text_annotations = response['textAnnotations'] if response
    text_annotations || []
  end
  
  def reasonable_width
    200
  end
  
  def reasonable_height
    200
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
end

class AnnotationMerger
  def initialize(annotations)
    @annotations = annotations
  end
  
  def merged
    Annotation.new(
      @annotations.map(&:description).join,
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
end

class Point
  attr_reader :x, :y
  
  def initialize(x, y)
    @x = x
    @y = y
  end
end

class Tracer
  def initialize(io)
    @io = io
    @scope_level = 0
  end
  
  def trace(message, annotations = nil, &block)
    if annotations
      print("#{message}: #{summarize(annotations)}")
    else
      print(message)
    end
    
    enter_scope
    results = block.call
    exit_scope
    
    print("#{message} results: #{summarize(results)}")
    results
  end
  
  private
  
  def summarize(annotations)
    annotations = if annotations.nil?
      []
    elsif !annotations.is_a?(Array)
      [annotations]
    else
      annotations
    end
      
    annotations.map(&:description).join(', ')
  end
  
  def print(message)
    @io.puts("#{indentation}#{message}")
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
  attr_reader :left_number, :decimal, :right_number
  
  def initialize(result)
    @result = result
    @state = :left
    @left_number = nil
    @decimal = nil
    @right_number = nil
  end
  
  def process(annotation)
    @state = if @state == :left
      process_left(annotation)
    elsif @state == :decimal
      process_decimal(annotation)
    elsif @state == :right
      process_right(annotation)
    end
  end
  
  def finish
    @result << @left_number if @left_number
    @result << @decimal if @decimal
  end
  
  private
  
  def process_left(annotation)
    if number?(annotation)
      @left_number = annotation
      :decimal
    else
      @result << annotation
      reset
    end
  end
  
  def process_decimal(annotation)
    if decimal?(annotation)
      @decimal = annotation
      :right
    else
      @result << @left_number
      @result << annotation
      reset
    end
  end
  
  def process_right(annotation)
    if number?(annotation)
      @right_number = annotation
      @result << AnnotationMerger.new([@left_number, @decimal, @right_number]).merged
      reset
    else
      @result << @left_number
      @result << @decimal
      @result << annotation
      reset
    end
  end
  
  def reset
    @left_number = nil
    @decimal = nil
    @right_number = nil
    @state = :left
    
    @state
  end
  
  def number?(annotation)
    annotation.description =~ /\d+/
  end
  
  def decimal?(annotation)
    annotation.description == '.'
  end
end

class DecimalNumberMerger  
  def merge(annotations)
    result = []
    state_machine = DecimalNumberStateMachine.new(result)
    
    annotations.each do |annotation|
      state_machine.process(annotation)
    end
    state_machine.finish
    
    result
  end
end

module TotalPaymentAmount
  class LookToTheRightStrategy
    def initialize(tracer)
      @tracer = tracer
    end
  
    def find(annotations)    
      first_total_payment_amount(annotations)
    end  
  
    private
  
    def first_total_payment_amount(annotations)
      @tracer.trace('Finding first total payment amount') do
        all_total_payment_amounts(annotations).first
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
          annotation.description.downcase == 'due' ||
          annotation.description.downcase == 'total' ||
          annotation.description.downcase == 'balance'
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
          annotation.description =~ /\A\d+\.\d+\z/ ? annotation : nil
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


annotations = AnnotationsFactory.new(JSON.parse(File.read(file))).create_annotations
puts TotalPaymentAmount::LookToTheRightStrategy.new(Tracer.new($stdout)).find(annotations).description
