require 'open3'
require 'tap_parser'
require 'audit'
require 'headless'

class PythonStyleGrader < Grader
  def autograde?
    true
  end

  def display_type
    "Python Style"
  end
  
  def to_s
    if self.upload
      "#{self.avail_score} points: Run Python style checker, using #{self.upload.file_name}"
    else
      "#{self.avail_score} points: Run Python style checker"
    end
  end

  after_initialize :load_style_params
  before_validation :set_style_params

  def assign_attributes(attrs)
    super
    set_style_params
  end
  
  protected
  
  def do_grading(assignment, sub)
    g = self.grade_for sub
    Dir.mktmpdir("grade-#{sub.id}-#{g.id}_") do |tmpdir|
      @tmpdir = tmpdir
      sub.upload.extract_contents_to!(nil, Pathname.new(tmpdir), false)
      Headless.ly(display: g.id) do
        run_command_produce_tap assignment, sub, timeout: Grader::DEFAULT_GRADING_TIMEOUT
      end
    end
  end

  def get_command_arguments(assignment, sub)
    ans = [
      "style.tap",
      {"XDG_RUNTIME_DIR" => nil},
      ["python", Rails.root.join("lib/assets/checkstyle.py").to_s,
       "--grade-config", Rails.root.join("lib/assets/python-config.json").to_s,
       "--max-points", self.avail_score.to_s,
       "--max-line-length", self.line_length.to_s,
       @tmpdir],
      [[@tmpdir, Upload.upload_path_for(sub.upload.extracted_path.to_s)]].to_h
    ]
    if self.upload&.submission_path && File.file?(self.upload.submission_path)
      ans[2].insert(4,
                    "--grade-config", self.upload.submission_path.to_s)
    end
    ans
  end

  def load_style_params
    return if new_record?
    self.line_length = self.params.to_i
  end

  def set_style_params
    self.params = "#{self.line_length}"
  end

  def recompute_grades
    # nothing to do:
    # we already compute the score here based on the TAP output
  end
end