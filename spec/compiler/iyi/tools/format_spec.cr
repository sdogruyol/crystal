{% skip_file if flag?(:bits32) %}

require "spec"
require "compiler/iyi/formatter"
require "compiler/iyi/command/format"
require "../../../support/tempfile"

private class BuggyFormatCommand < Iyi::Command::FormatCommand
  def format(filename, source)
    raise "format command test"
  end
end

describe Iyi::Command::FormatCommand do
  it "formats stdin" do
    stdin = IO::Memory.new "if true\n1\nend"
    stdout = IO::Memory.new
    stderr = IO::Memory.new

    format_command = Iyi::Command::FormatCommand.new(["-"], stdin: stdin, stdout: stdout, stderr: stderr)
    format_command.run
    format_command.status_code.should eq(0)
    stdout.to_s.should eq("if true\n  1\nend\n")
    stderr.to_s.should be_empty
  end

  it "formats stdin (formatted)" do
    stdin = IO::Memory.new "if true\n  1\nend\n"
    stdout = IO::Memory.new
    stderr = IO::Memory.new

    format_command = Iyi::Command::FormatCommand.new(["-"], stdin: stdin, stdout: stdout, stderr: stderr)
    format_command.run
    format_command.status_code.should eq(0)
    stdout.to_s.should eq("if true\n  1\nend\n")
    stderr.to_s.should be_empty
  end

  it "formats stdin (syntax error)" do
    stdin = IO::Memory.new "if"
    stdout = IO::Memory.new
    stderr = IO::Memory.new

    format_command = Iyi::Command::FormatCommand.new(["-"], stdin: stdin, stdout: stdout, stderr: stderr)
    format_command.run
    format_command.status_code.should eq(1)
    stdout.to_s.should be_empty
    stderr.to_s.should contain("syntax error in 'STDIN:1:3': unexpected token: EOF")
  end

  it "formats stdin (invalid byte sequence error)" do
    stdin = IO::Memory.new "\xfe\xff"
    stdout = IO::Memory.new
    stderr = IO::Memory.new

    format_command = Iyi::Command::FormatCommand.new(["-"], stdin: stdin, stdout: stdout, stderr: stderr)
    format_command.run
    format_command.status_code.should eq(1)
    stdout.to_s.should be_empty
    stderr.to_s.should contain("file 'STDIN' is not a valid iyi source file: Unexpected byte 0xfe at position 0, malformed UTF-8")
  end

  it "formats stdin (bug)" do
    stdin = IO::Memory.new ""
    stdout = IO::Memory.new
    stderr = IO::Memory.new

    format_command = BuggyFormatCommand.new(["-"], stdin: stdin, stdout: stdout, stderr: stderr)
    format_command.run
    format_command.status_code.should eq(1)
    stdout.to_s.should be_empty
    stderr.to_s.should contain("there's a bug formatting 'STDIN', to show more information, please run:\n\n  $ iyi tool format --show-backtrace -")
  end

  it "formats stdin (bug + show-backtrace)" do
    stdin = IO::Memory.new ""
    stdout = IO::Memory.new
    stderr = IO::Memory.new

    format_command = BuggyFormatCommand.new(["-"], show_backtrace: true, stdin: stdin, stdout: stdout, stderr: stderr)
    format_command.run
    format_command.status_code.should eq(1)
    stdout.to_s.should be_empty
    stderr.to_s.should contain("format command test")
    stderr.to_s.should contain("couldn't format 'STDIN', please report a bug including the contents of it: https://github.com/sdogruyol/iyi/issues")
  end

  it "formats files" do
    stdin = IO::Memory.new ""
    stdout = IO::Memory.new
    stderr = IO::Memory.new

    with_tempdir do
      File.write "format.iyi", "if true\n1\nend"
      File.write "not_format.iyi", "if true\n  1\nend\n"
      File.write "compat.cr", "if true\n1\nend"

      format_command = Iyi::Command::FormatCommand.new([] of String, color: false, stdin: stdin, stdout: stdout, stderr: stderr)
      format_command.run
      format_command.status_code.should eq(0)
      stdout.to_s.should contain("Format #{Path[".", "format.iyi"]}")
      stdout.to_s.should_not contain("Format #{Path[".", "not_format.iyi"]}")
      stdout.to_s.should_not contain("compat.cr")
      stderr.to_s.should be_empty

      File.read("format.iyi").should eq("if true\n  1\nend\n")
      File.read("compat.cr").should eq("if true\n1\nend")
    end
  end

  it "formats files (dir)" do
    stdin = IO::Memory.new ""
    stdout = IO::Memory.new
    stderr = IO::Memory.new

    with_tempdir do
      Dir.mkdir "dir"
      File.write "format.iyi", "if true\n1\nend"
      File.write "not_format.iyi", "if true\n  1\nend\n"
      File.write File.join("dir", "format.iyi"), "if true\n1\nend"
      File.write File.join("dir", "not_format.iyi"), "if true\n  1\nend\n"
      File.write File.join("dir", "compat.cr"), "if true\n1\nend"

      format_command = Iyi::Command::FormatCommand.new(["dir"], color: false, stdin: stdin, stdout: stdout, stderr: stderr)
      format_command.run
      format_command.status_code.should eq(0)
      stdout.to_s.should contain("Format #{Path[".", "dir", "format.iyi"]}")
      stdout.to_s.should_not contain("Format #{Path[".", "dir", "not_format.iyi"]}")
      stdout.to_s.should_not contain("compat.cr")
      stderr.to_s.should be_empty

      {stdout, stderr}.each &.clear

      format_command = Iyi::Command::FormatCommand.new([] of String, color: false, stdin: stdin, stdout: stdout, stderr: stderr)
      format_command.run
      format_command.status_code.should eq(0)
      stdout.to_s.should contain("Format #{Path[".", "format.iyi"]}")
      stdout.to_s.should_not contain("Format #{Path[".", "not_format.iyi"]}")
      stdout.to_s.should_not contain("Format #{Path[".", "dir", "format.iyi"]}")
      stdout.to_s.should_not contain("Format #{Path[".", "dir", "not_format.iyi"]}")
      stderr.to_s.should be_empty

      File.read("format.iyi").should eq("if true\n  1\nend\n")
      File.read(File.join("dir", "format.iyi")).should eq("if true\n  1\nend\n")
      File.read(File.join("dir", "compat.cr")).should eq("if true\n1\nend")
    end
  end

  it "formats files (error)" do
    stdin = IO::Memory.new ""
    stdout = IO::Memory.new
    stderr = IO::Memory.new

    with_tempdir do
      File.write "format.iyi", "if true\n1\nend"
      File.write "syntax_error.iyi", "if"
      File.write "invalid_byte_sequence_error.iyi", "\xfe\xff"

      format_command = Iyi::Command::FormatCommand.new([] of String, color: false, stdin: stdin, stdout: stdout, stderr: stderr)
      format_command.run
      format_command.status_code.should eq(1)
      stdout.to_s.should contain("Format #{Path[".", "format.iyi"]}")
      stderr.to_s.should contain("syntax error in '#{Path[".", "syntax_error.iyi"]}:1:3': unexpected token: EOF")
      stderr.to_s.should contain("file '#{Path[".", "invalid_byte_sequence_error.iyi"]}' is not a valid iyi source file: Unexpected byte 0xfe at position 0, malformed UTF-8")

      File.read("format.iyi").should eq("if true\n  1\nend\n")
    end
  end

  it "formats files (bug)" do
    stdin = IO::Memory.new ""
    stdout = IO::Memory.new
    stderr = IO::Memory.new

    with_tempdir do
      File.write "empty.iyi", ""

      format_command = BuggyFormatCommand.new([] of String, color: false, stdin: stdin, stdout: stdout, stderr: stderr)
      format_command.run
      format_command.status_code.should eq(1)
      stderr.to_s.should contain("there's a bug formatting '#{Path[".", "empty.iyi"]}', to show more information, please run:\n\n  $ iyi tool format --show-backtrace '#{Path[".", "empty.iyi"]}'")
    end
  end

  it "formats files (bug + show-stacktrace)" do
    stdin = IO::Memory.new ""
    stdout = IO::Memory.new
    stderr = IO::Memory.new

    with_tempdir do
      File.write "empty.iyi", ""

      format_command = BuggyFormatCommand.new([] of String, show_backtrace: true, color: false, stdin: stdin, stdout: stdout, stderr: stderr)
      format_command.run
      format_command.status_code.should eq(1)
      stderr.to_s.should contain("format command test")
      stderr.to_s.should contain("couldn't format '#{Path[".", "empty.iyi"]}', please report a bug including the contents of it: https://github.com/sdogruyol/iyi/issues")
    end
  end

  it "checks files format" do
    stdin = IO::Memory.new ""
    stdout = IO::Memory.new
    stderr = IO::Memory.new

    with_tempdir do
      File.write "format.iyi", "if true\n1\nend"
      File.write "not_format.iyi", "if true\n  1\nend\n"
      File.write "syntax_error.iyi", "if"
      File.write "invalid_byte_sequence_error.iyi", "\xfe\xff"

      format_command = Iyi::Command::FormatCommand.new([] of String, check: true, color: false, stdin: stdin, stdout: stdout, stderr: stderr)
      format_command.run
      format_command.status_code.should eq(1)
      stdout.to_s.should be_empty
      stderr.to_s.should_not contain("not_format.iyi")
      stderr.to_s.should contain("formatting '#{Path[".", "format.iyi"]}' produced changes")
      stderr.to_s.should contain("syntax error in '#{Path[".", "syntax_error.iyi"]}:1:3': unexpected token: EOF")
      stderr.to_s.should contain("file '#{Path[".", "invalid_byte_sequence_error.iyi"]}' is not a valid iyi source file: Unexpected byte 0xfe at position 0, malformed UTF-8")
    end
  end

  it "checks files format (ok)" do
    stdin = IO::Memory.new ""
    stdout = IO::Memory.new
    stderr = IO::Memory.new

    with_tempdir do
      File.write "format1.iyi", "if true\n  1\nend\n"
      File.write "format2.iyi", "if true\n  2\nend\n"

      format_command = Iyi::Command::FormatCommand.new([] of String, check: true, color: false, stdin: stdin, stdout: stdout, stderr: stderr)
      format_command.run
      format_command.status_code.should eq(0)
      stdout.to_s.should be_empty
      stderr.to_s.should be_empty
    end
  end

  it "checks files format (excludes)" do
    stdin = IO::Memory.new ""
    stdout = IO::Memory.new
    stderr = IO::Memory.new

    with_tempdir do
      File.write "format.iyi", "if true\n1\nend"
      File.write "not_format.iyi", "if true\n  1\nend\n"

      format_command = Iyi::Command::FormatCommand.new([] of String, check: true, excludes: ["format.iyi"], color: false, stdin: stdin, stdout: stdout, stderr: stderr)
      format_command.run
      format_command.status_code.should eq(0)
      stdout.to_s.should be_empty
      stderr.to_s.should be_empty
    end
  end

  it "checks files format (excludes + includes)" do
    stdin = IO::Memory.new ""
    stdout = IO::Memory.new
    stderr = IO::Memory.new

    with_tempdir do
      File.write "format.iyi", "if true\n1\nend"
      File.write "not_format.iyi", "if true\n  1\nend\n"

      format_command = Iyi::Command::FormatCommand.new([] of String, check: true, excludes: ["format.iyi"], includes: ["format.iyi"], color: false, stdin: stdin, stdout: stdout, stderr: stderr)
      format_command.run
      format_command.status_code.should eq(1)
      stdout.to_s.should be_empty
      stderr.to_s.should contain("formatting '#{Path[".", "format.iyi"]}' produced changes")
    end
  end
end
