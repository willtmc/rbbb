# frozen_string_literal: true

require "rake/testtask"

desc "Validate language-neutral repository documents"
task :validate do
  ruby "scripts/validate_documents.rb"
end

Rake::TestTask.new(:test) do |task|
  task.libs << "ruby/engine/lib"
  task.libs << "ruby/engine/test"
  task.pattern = "ruby/engine/test/**/*_test.rb"
end

task default: %i[validate test]
