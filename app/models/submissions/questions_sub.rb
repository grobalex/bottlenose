require 'securerandom'
require 'audit'

class QuestionsSub < Submission
  include SubmissionsHelper
  validate :check_time_taken


  def grade_question(who_graded, grade_id, message, question, score)
    comment = InlineComment.find_or_initialize_by(submission: self,  grade_id: grade_id, line: question)
    comment.update(label: "Graded question",
                   filename: self.assignment.name,
                   severity: InlineComment.severities["info"],
                   user_id: (who_graded || self.user).id,
                   weight: score,
                   comment: message.empty? ?  "" : message,
                   suppressed: false,
                   title: "",
                   info: nil)
    comment
  end

  def check_time_taken
    if self.assignment.request_time_taken && @time_taken.empty?
      self.errors.add(:base, "Please specify how long you have worked on this assignment")
    elsif @time_taken and !(Float(@time_taken) rescue false)
      self.errors.add(:base, "Please specify a valid number for how long you have worked on this assignment")
    end
    return self.errors.count == 0
  end
  attr_accessor :answers
  def save_upload(prof_override = nil)
    if @answers.nil?
      errors.add(:base, "You need to submit a file.")
      return false
    end
    Tempfile.open('answers.yaml', Rails.root.join('tmp')) do |f|
      f.write(YAML.dump(@answers))
      f.flush
      f.rewind
      uploadfile = ActionDispatch::Http::UploadedFile.new(filename: "answers.yaml", tempfile: f)
      self.upload_file = uploadfile
      super
    end
  end
  attr_accessor :related_files
  validate :check_all_questions
  def check_all_questions
    return true unless self.new_record?
    questions = self.assignment.flattened_questions
    all_questions = [["newsub", questions]].to_h
    num_qs = questions.count
    if @answers.count != num_qs
      self.errors.add(:base, "There were #{pluralize(@answers.count, 'answer')} for #{pluralize(num_qs, 'question')}")
      self.cleanup!
    else
      check_questions_schema(all_questions, [["newsub", @answers]].to_h, questions.count)
    end
  end
end
