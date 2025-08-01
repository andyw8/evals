# Evals

A Ruby library for evaluating LLM responses.

Based on the Prompt Evaluation example in the [Anthropic Skilljar course](https://anthropic.skilljar.com/claude-with-the-anthropic-api).

## Installation

Install the gem and add to the application's Gemfile by executing:

```bash
bundle add evals
```

If bundler is not being used to manage dependencies, install the gem by executing:

```bash
gem install evals
```

## Configuration

Copy `.env.example` to `.env` and add your Anthropic API key.

## Usage

See [examples/demo.rb](examples/demo.rb) for an example.

## Development

After checking out the repo, run `bin/setup` to install dependencies. Then, run `rake test` to run the tests. You can also run `bin/console` for an interactive prompt that will allow you to experiment.

To install this gem onto your local machine, run `bundle exec rake install`. To release a new version, update the version number in `version.rb`, and then run `bundle exec rake release`, which will create a git tag for the version, push git commits and the created tag, and push the `.gem` file to [rubygems.org](https://rubygems.org).

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/andyw8/evals.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
