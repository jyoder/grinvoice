require 'csv'
require_relative 'grinvoice_lib'

if ARGV.length != 1
  puts('usage: ruby parse-bill.rb file.ocr')
  exit 1
end
file = ARGV.first

annotations = AnnotationsFactory.new(JSON.parse(File.read(file))).create_annotations
annotation = TotalPaymentAmount::LookToTheRightComposerStrategy.new(Tracer.new($stdout)).find(annotations)
total_amount = annotation ? annotation.description.gsub(' ', '').gsub(',', '') : ''

annotation = InvoiceDates::LookToTheRightComposerStrategy.new(Tracer.new($stdout)).find(annotations)
due_date = annotation ? DateParser.parse(annotation.description).to_s : ''

file =~ /(.*)_\d+/
csv = "#{$1}.csv"

data = CSV.read(csv)
actual_total_amount = data[1][3]
actual_due_date = data[1][8]

puts
puts "image: #{file}"
puts "csv: #{csv}"
puts
puts "actual total amount: #{actual_total_amount}"
puts "found total amount: #{total_amount}"
puts "total amount match: #{total_amount == actual_total_amount}"
puts
puts "actual due date: #{actual_due_date}"
puts "found due date: #{due_date}"
puts "due date match: #{due_date == actual_due_date}"
puts
