require 'base64'


if ARGV.length < 1
  puts "usage: process-image.rb image.png"
  exit
end

content = Base64.encode64(File.read(ARGV[0]))
request = <<-HEREDOC
{
  "requests":[
    {
      "image": {
        "content":"#{content.strip}"
      },
      "features":[
        {
          "type": "DOCUMENT_TEXT_DETECTION",
          "maxResults":1
        }
      ]
    }
  ]
}
HEREDOC

File.open('request.json', 'w+') do |file|
  file.puts(request)
end

`curl -H "Content-Type: application/json" --data-binary @request.json "https://vision.googleapis.com/v1/images:annotate?key=XXXX" > "#{ARGV[0]}.ocr"`
