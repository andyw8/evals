require "json"
require "net/http"
require "uri"

module Evals
  class PromptEvaluator
    def initialize(max_concurrent_tasks: 3)
      @max_concurrent_tasks = max_concurrent_tasks
      @client = Anthropic::Client.new(api_key: ENV["ANTHROPIC_API_KEY"])
      @model = "claude-3-5-haiku-latest"
    end

    def render(template_string, variables)
      placeholders = template_string.scan(/{([^{}]+)}/)

      result = template_string
      placeholders.flatten.each do |placeholder|
        if variables.key?(placeholder)
          result = result.gsub("{#{placeholder}}", variables[placeholder].to_s)
        end
      end

      result.gsub("{{", "{").gsub("}}", "}")
    end

    def add_user_message(messages, text)
      messages << {role: "user", content: text}
    end

    def add_assistant_message(messages, text)
      messages << {role: "assistant", content: text}
    end

    def chat(messages, system: nil, temperature: 1.0, stop_sequences: [])
      params = {
        model: @model,
        max_tokens: 1000,
        messages: messages,
        temperature: temperature,
        stop_sequences: stop_sequences
      }

      params[:system] = system if system

      response = @client.messages.create(params)
      response.content[0].text
    end

    def generate_unique_ideas(task_description, prompt_inputs_spec, num_cases)
      prompt = <<~TEXT
        Generate #{num_cases} unique, diverse ideas for testing a prompt that accomplishes this task:

        <task_description>
        #{task_description}
        </task_description>

        The prompt will receive the following inputs
        <prompt_inputs>
        #{prompt_inputs_spec}
        </prompt_inputs>

        Each idea should represent a distinct scenario or example that tests different aspects of the task.

        Output Format:
        Provide your response as a structured JSON array where each item is a brief description of the idea.

        Example:
        ```json
        [
            "Testing with technical computer science terminology",
            "Testing with medical research findings",
            "Testing with complex mathematical concepts",
            ...
        ]
        ```

        Ensure each idea is:
        - Clearly distinct from the others
        - Relevant to the task description
        - Specific enough to guide generation of a full test case
        - Quick to solve without requiring extensive computation or multi-step processing
        - Solvable with no more than 400 tokens of output

        Remember, only generate #{num_cases} unique ideas
      TEXT

      system_prompt = "You are a test scenario designer specialized in creating diverse, unique testing scenarios."

      example_prompt_inputs = ""
      prompt_inputs_spec.each do |key, value|
        val = value.gsub("\n", "\\n")
        example_prompt_inputs += "\"#{key}\": str # #{val},"
      end

      rendered_prompt = render(
        prompt.strip,
        {
          "task_description" => task_description,
          "num_cases" => num_cases,
          "prompt_inputs" => example_prompt_inputs
        }
      )

      messages = []
      add_user_message(messages, rendered_prompt)
      add_assistant_message(messages, "```json")
      text = chat(
        messages,
        stop_sequences: ["```"],
        system: system_prompt,
        temperature: 1.0
      )

      JSON.parse(text)
    end

    def generate_test_case(task_description, idea, prompt_inputs_spec = {})
      example_prompt_inputs = ""
      prompt_inputs_spec.each do |key, value|
        val = value.gsub("\n", "\\n")
        example_prompt_inputs += "\"#{key}\": \"EXAMPLE_VALUE\", // #{val}\n"
      end

      allowed_keys = prompt_inputs_spec.keys.map { |key| "\"#{key}\"" }.join(", ")

      prompt = <<~TEXT
        Generate a single detailed test case for a prompt evaluation based on:

        <task_description>
        #{task_description}
        </task_description>

        <specific_idea>
        #{idea}
        </specific_idea>

        <allowed_input_keys>
        #{allowed_keys}
        </allowed_input_keys>

        Output Format:
        ```json
        {
            "prompt_inputs": {
            #{example_prompt_inputs}
            },
            "solution_criteria": ["criterion 1", "criterion 2", ...] // Concise list of criteria for evaluating the solution, 1 to 4 items
        }
        ```

        IMPORTANT REQUIREMENTS:
        - You MUST ONLY use these exact input keys in your prompt_inputs: #{allowed_keys}
        - Do NOT add any additional keys to prompt_inputs
        - All keys listed in allowed_input_keys must be included in your response
        - Make the test case realistic and practically useful
        - Include measurable, concise solution criteria
        - The solution criteria should ONLY address the direct requirements of the task description and the generated prompt_inputs
        - Avoid over-specifying criteria with requirements that go beyond the core task
        - Keep solution criteria simple, focused, and directly tied to the fundamental task
        - The test case should be tailored to the specific idea provided
        - Quick to solve without requiring extensive computation or multi-step processing
        - Solvable with no more than 400 tokens of output
        - DO NOT include any fields beyond those specified in the output format
      TEXT

      system_prompt = "You are a test case creator specializing in designing evaluation scenarios."

      rendered_prompt = render(
        prompt.strip,
        {
          "allowed_keys" => allowed_keys,
          "task_description" => task_description,
          "idea" => idea,
          "example_prompt_inputs" => example_prompt_inputs
        }
      )

      messages = []
      add_user_message(messages, rendered_prompt)
      add_assistant_message(messages, "```json")
      text = chat(
        messages,
        stop_sequences: ["```"],
        system: system_prompt,
        temperature: 0.7
      )

      test_case = JSON.parse(text)
      test_case["task_description"] = task_description
      test_case["scenario"] = idea

      test_case
    end

    def generate_dataset(task_description, prompt_inputs_spec: {}, num_cases: 1, output_file: "dataset.json")
      ideas = generate_unique_ideas(task_description, prompt_inputs_spec, num_cases)

      dataset = []
      completed = 0
      total = ideas.length
      last_reported_percentage = 0

      threads = ideas.map do |idea|
        Thread.new do
          generate_test_case(task_description, idea, prompt_inputs_spec)
        end
      end

      threads.each do |thread|
        result = thread.value
        completed += 1
        current_percentage = ((completed.to_f / total) * 100).to_i
        milestone_percentage = (current_percentage / 20) * 20

        if milestone_percentage > last_reported_percentage
          puts "Generated #{completed}/#{total} test cases"
          last_reported_percentage = milestone_percentage
        end

        dataset << result
      rescue => e
        puts "Error generating test case: #{e}"
      end

      File.write(output_file, JSON.pretty_generate(dataset))
      dataset
    end

    def grade_output(test_case, output, extra_criteria)
      prompt_inputs = ""
      test_case["prompt_inputs"].each do |key, value|
        val = value.gsub("\n", "\\n")
        prompt_inputs += "\"#{key}\":\"#{val}\",\n"
      end

      extra_criteria_section = ""
      if extra_criteria
        extra_criteria_template = <<~TEXT
          Mandatory Requirements - ANY VIOLATION MEANS AUTOMATIC FAILURE (score of 3 or lower):
          <extra_important_criteria>
          #{extra_criteria}
          </extra_important_criteria>
        TEXT
        extra_criteria_section = render(
          extra_criteria_template.strip,
          {"extra_criteria" => extra_criteria}
        )
      end

      eval_template = <<~TEXT
        Your task is to evaluate the following AI-generated solution with EXTREME RIGOR.

        Original task description:
        <task_description>
        #{test_case["task_description"]}
        </task_description>

        Original task inputs:
        <task_inputs>
        { #{prompt_inputs} }
        </task_inputs>

        Solution to Evaluate:
        <solution>
        #{output}
        </solution>

        Criteria you should use to evaluate the solution:
        <criteria>
        #{test_case["solution_criteria"].join("\n")}
        </criteria>

        #{extra_criteria_section}

        Scoring Guidelines:
        * Score 1-3: Solution fails to meet one or more MANDATORY requirements
        * Score 4-6: Solution meets all mandatory requirements but has significant deficiencies in secondary criteria
        * Score 7-8: Solution meets all mandatory requirements and most secondary criteria, with minor issues
        * Score 9-10: Solution meets all mandatory and secondary criteria

        IMPORTANT SCORING INSTRUCTIONS:
        * Grade the output based ONLY on the listed criteria. Do not add your own extra requirements.
        * If a solution meets all of the mandatory and secondary criteria give it a 10
        * Don't complain that the solution "only" meets the mandatory and secondary criteria. Solutions shouldn't go above and beyond - they should meet the exact listed criteria.
        * ANY violation of a mandatory requirement MUST result in a score of 3 or lower
        * The full 1-10 scale should be utilized - don't hesitate to give low scores when warranted

        Output Format
        Provide your evaluation as a structured JSON object with the following fields, in this specific order:
        - "strengths": An array of 1-3 key strengths
        - "weaknesses": An array of 1-3 key areas for improvement
        - "reasoning": A concise explanation of your overall assessment
        - "score": A number between 1-10

        Respond with JSON. Keep your response concise and direct.
      TEXT

      eval_prompt = render(
        eval_template.strip,
        {
          "task_description" => test_case["task_description"],
          "prompt_inputs" => prompt_inputs,
          "output" => output,
          "solution_criteria" => test_case["solution_criteria"].join("\n"),
          "extra_criteria_section" => extra_criteria_section
        }
      )

      messages = []
      add_user_message(messages, eval_prompt)
      add_assistant_message(messages, "```json")
      eval_text = chat(
        messages,
        stop_sequences: ["```"],
        temperature: 0.0
      )

      JSON.parse(eval_text)
    end

    def run_test_case(test_case, run_prompt_function, extra_criteria = nil)
      output = run_prompt_function.call(test_case["prompt_inputs"])

      model_grade = grade_output(test_case, output, extra_criteria)
      model_score = model_grade["score"]
      reasoning = model_grade["reasoning"]

      {
        "output" => output,
        "test_case" => test_case,
        "score" => model_score,
        "reasoning" => reasoning
      }
    end

    def run_evaluation(run_prompt_function, dataset_file, extra_criteria: nil, json_output_file: "output.json", html_output_file: "output.html")
      dataset = JSON.parse(File.read(dataset_file))

      results = []
      completed = 0
      total = dataset.length
      last_reported_percentage = 0

      threads = dataset.map do |test_case|
        Thread.new do
          run_test_case(test_case, run_prompt_function, extra_criteria)
        end
      end

      threads.each do |thread|
        result = thread.value
        completed += 1
        current_percentage = ((completed.to_f / total) * 100).to_i
        milestone_percentage = (current_percentage / 20) * 20

        if milestone_percentage > last_reported_percentage
          puts "Graded #{completed}/#{total} test cases"
          last_reported_percentage = milestone_percentage
        end

        results << result
      end

      average_score = results.sum { |result| result["score"] } / results.length.to_f
      puts "Average score: #{average_score}"

      File.write(json_output_file, JSON.pretty_generate(results))

      html = generate_prompt_evaluation_report(results)
      File.write(html_output_file, html)

      results
    end

    private

    def generate_prompt_evaluation_report(evaluation_results)
      total_tests = evaluation_results.length
      scores = evaluation_results.map { |result| result["score"] }
      avg_score = scores.empty? ? 0 : scores.sum.to_f / scores.length
      max_possible_score = 10
      pass_rate = if total_tests > 0
        100.0 * scores.count { |s| s >= 7 } / total_tests
      else
        0
      end

      html = <<~HTML
        <!DOCTYPE html>
        <html lang="en">
        <head>
            <meta charset="UTF-8">
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
            <title>Prompt Evaluation Report</title>
            <style>
                body {
                    font-family: Arial, sans-serif;
                    line-height: 1.6;
                    margin: 0;
                    padding: 20px;
                    color: #333;
                }
                .header {
                    background-color: #f0f0f0;
                    padding: 20px;
                    border-radius: 5px;
                    margin-bottom: 20px;
                }
                .summary-stats {
                    display: flex;
                    justify-content: space-between;
                    flex-wrap: wrap;
                    gap: 10px;
                }
                .stat-box {
                    background-color: #fff;
                    border-radius: 5px;
                    padding: 15px;
                    box-shadow: 0 2px 5px rgba(0,0,0,0.1);
                    flex-basis: 30%;
                    min-width: 200px;
                }
                .stat-value {
                    font-size: 24px;
                    font-weight: bold;
                    margin-top: 5px;
                }
                table {
                    width: 100%;
                    border-collapse: collapse;
                    margin-top: 20px;
                }
                th {
                    background-color: #4a4a4a;
                    color: white;
                    text-align: left;
                    padding: 12px;
                }
                td {
                    padding: 10px;
                    border-bottom: 1px solid #ddd;
                    vertical-align: top;
                }
                tr:nth-child(even) {
                    background-color: #f9f9f9;
                }
                .output-cell {
                    white-space: pre-wrap;
                }
                .score {
                    font-weight: bold;
                    padding: 5px 10px;
                    border-radius: 3px;
                    display: inline-block;
                }
                .score-high {
                    background-color: #c8e6c9;
                    color: #2e7d32;
                }
                .score-medium {
                    background-color: #fff9c4;
                    color: #f57f17;
                }
                .score-low {
                    background-color: #ffcdd2;
                    color: #c62828;
                }
                .output {
                    overflow: auto;
                    white-space: pre-wrap;
                }
                .output pre {
                    background-color: #f5f5f5;
                    border: 1px solid #ddd;
                    border-radius: 4px;
                    padding: 10px;
                    margin: 0;
                    font-family: 'Consolas', 'Monaco', 'Courier New', monospace;
                    font-size: 14px;
                    line-height: 1.4;
                    color: #333;
                    box-shadow: inset 0 1px 3px rgba(0, 0, 0, 0.1);
                    overflow-x: auto;
                    white-space: pre-wrap;
                    word-wrap: break-word;
                }
                td {
                    width: 20%;
                }
                .score-col {
                    width: 80px;
                }
            </style>
        </head>
        <body>
            <div class="header">
                <h1>Prompt Evaluation Report</h1>
                <div class="summary-stats">
                    <div class="stat-box">
                        <div>Total Test Cases</div>
                        <div class="stat-value">#{total_tests}</div>
                    </div>
                    <div class="stat-box">
                        <div>Average Score</div>
                        <div class="stat-value">#{sprintf("%.1f", avg_score)} / #{max_possible_score}</div>
                    </div>
                    <div class="stat-box">
                        <div>Pass Rate (≥7)</div>
                        <div class="stat-value">#{sprintf("%.1f", pass_rate)}%</div>
                    </div>
                </div>
            </div>

            <table>
                <thead>
                    <tr>
                        <th>Scenario</th>
                        <th>Prompt Inputs</th>
                        <th>Solution Criteria</th>
                        <th>Output</th>
                        <th>Score</th>
                        <th>Reasoning</th>
                    </tr>
                </thead>
                <tbody>
      HTML

      evaluation_results.each do |result|
        prompt_inputs_html = result["test_case"]["prompt_inputs"].map do |key, value|
          "<strong>#{key}:</strong> #{value}"
        end.join("<br>")

        criteria_string = result["test_case"]["solution_criteria"].join("<br>• ")

        score = result["score"]
        score_class = if score >= 8
          "score-high"
        elsif score <= 5
          "score-low"
        else
          "score-medium"
        end

        html += <<~HTML
          <tr>
              <td>#{result["test_case"]["scenario"]}</td>
              <td class="prompt-inputs">#{prompt_inputs_html}</td>
              <td class="criteria">• #{criteria_string}</td>
              <td class="output"><pre>#{result["output"]}</pre></td>
              <td class="score-col"><span class="score #{score_class}">#{score}</span></td>
              <td class="reasoning">#{result["reasoning"]}</td>
          </tr>
        HTML
      end

      html += <<~HTML
                </tbody>
            </table>
        </body>
        </html>
      HTML

      html
    end
  end
end
