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

namespace :package do
  desc "Build, inspect, install, and smoke-test the Ruby evaluation gem"
  task :verify do
    Dir.chdir("ruby/engine") do
      ruby "script/verify_package.rb"
    end
  end
end

task default: [:validate, :test, "package:verify"]
