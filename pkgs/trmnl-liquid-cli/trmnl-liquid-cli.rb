require 'trmnl/liquid'
require 'optparse'
require 'json'
require 'cgi'

# CLI examples:
# - Template from file, context inline: ruby trmnl-liquid-cli.rb -i template.liquid -c '{"count":1337}'
# - Template from file, context from file: ruby trmnl-liquid-cli.rb -i template.liquid -C context.json
# - From string (HTML-encoded): ruby trmnl-liquid-cli.rb -t "Hello {{ name }}" -c '{"name":"World"}'
#   Note: when using -t/--template, pass a template string that was encoded via PHP: htmlspecialchars($template, ENT_QUOTES, 'UTF-8')
options = {}
OptionParser.new do |opts|
  opts.banner = 'Usage: ruby trmnl-liquid-cli.rb (-i INPUT_FILE | -t TEMPLATE) (-c JSON_CONTEXT | -C CONTEXT_FILE)'
  opts.on('-iFILE', '--input=FILE', 'Path to Liquid template file') { |v| options[:input] = v }
  opts.on('-tTEMPLATE', '--template=TEMPLATE', 'HTML-encoded Liquid template string (alternative to -i)') { |v| options[:template] = v }
  opts.on('-cJSON', '--context=JSON', 'JSON context (php json_encode with UNESCAPED flags supported)') { |v| options[:context] = v }
  opts.on('-CFILE', '--context-file=FILE', 'Path to JSON file for context (alternative to -c)') { |v| options[:context_file] = v }
  opts.on('-h', '--help', 'Show help') do
    puts opts
    exit 0
  end
end.parse!(ARGV)

# Validate that exactly one of -i/--input or -t/--template is provided
input_provided = options[:input] && !options[:input].strip.empty?
template_provided = options[:template] && !options[:template].strip.empty?

if input_provided && template_provided
  warn 'Error: provide either -i/--input or -t/--template, not both'
  exit 1
elsif !input_provided && !template_provided
  warn 'Error: missing template. Provide -i FILE or -t TEMPLATE'
  exit 1
end

if input_provided && !File.file?(options[:input])
  warn "Error: input file not found: #{options[:input]}"
  exit 1
end

context_inline = options[:context]
context_file = options[:context_file] && !options[:context_file].strip.empty?

if context_inline && context_file
  warn 'Error: provide either -c/--context or -C/--context-file, not both'
  exit 1
elsif !context_inline && !context_file
  warn 'Error: missing context. Provide -c JSON or -C CONTEXT_FILE'
  exit 1
end

vars_str = if context_file
  path = options[:context_file]
  unless File.file?(path)
    warn "Error: context file not found: #{path}"
    exit 1
  end
  File.read(path)
else
  context_inline
end

def deep_stringify_keys(obj)
  case obj
  when Hash
    obj.each_with_object({}) do |(k, v), h|
      h[k.to_s] = deep_stringify_keys(v)
    end
  when Array
    obj.map { |e| deep_stringify_keys(e) }
  else
    obj
  end
end

# Parse context strictly as JSON (expects php json_encode with UNESCAPED_UNICODE | UNESCAPED_SLASHES)
variables = begin
  JSON.parse(vars_str)
rescue JSON::ParserError => e
  warn "Error: failed to parse context as JSON: #{e.message}"
  exit 2
end

unless variables.is_a?(Hash)
  warn 'Error: context must decode to a JSON object/map'
  exit 2
end

variables = deep_stringify_keys(variables)

markup = if input_provided
  File.read(options[:input])
else
  CGI.unescapeHTML(options[:template].to_s)
end
environment = TRMNL::Liquid.build_environment
template = Liquid::Template.parse(markup, environment: environment)
rendered = template.render(variables)

print rendered
