require 'tempfile'
require 'audit'

class SubmissionsController < CoursesController
  prepend_before_action :find_submission, except: [:index, :new, :create, :rerun_grader]
  prepend_before_action :find_course_assignment
  before_action :require_current_user, only: [:show, :files, :new, :create]
  before_action :require_admin_or_staff, only: [:recreate_grade, :rerun_grader, :use_for_grading, :publish]
  before_action :require_admin_or_prof, only: [:rescind_lateness, :edit_plagiarism, :update_plagiarism, :split_submission]
  def show
    unless @submission.visible_to?(current_user)
      redirect_to course_assignment_path(@course, @assignment), alert: "That's not your submission."
      return
    end

    self.send("show_#{@assignment.type.capitalize}")
    render "show_#{@assignment.type.underscore}"
  end

  def index
    redirect_to course_assignment_path(@course, @assignment)
  end

  def details
    unless @submission.visible_to?(current_user)
      redirect_to course_assignment_path(@course, @assignment), alert: "That's not your submission."
      return
    end

    self.send("details_#{@assignment.type.capitalize}")
  end

  def new
    @submission = Submission.new
    @submission.assignment_id = @assignment.id
    @submission.user_id = current_user.id

    if @assignment.team_subs?
      @team = current_user.active_team_for(@course, @assignment)

      if @team.nil? && current_user.course_staff?(@course)
        @team = Team.new(course: @course, start_date: DateTime.now, teamset: @assignment.teamset)
        @team.users = [current_user]
        @team.save
      end

      @submission.team = @team
    end

    self.send("new_#{@assignment.type.capitalize}")
  end

  def create
    asgn_type = @assignment.type
    sub_type = submission_params[:type]
    case [asgn_type, sub_type]
    when ["Files", "FilesSub"] then true
    when ["Questions", "QuestionsSub"] then true
    when ["Exam", "ExamSub"] then true
    else
      redirect_to course_assignment_path(@course, @assignment),
                  alert: "That submission type (#{sub_type}) does not match the assignment type (#{asgn_type})."
      return
    end

    @submission = Submission.new(submission_params)
    @submission.assignment = @assignment
    if @assignment.team_subs?
      @team = current_user.active_team_for(@course, @assignment)
      @submission.team = @team
    end

    @row_user = User.find_by_id(params[:row_user_id])

    if true_user_staff_for?(@course) || current_user_staff_for?(@course)
      @submission.user ||= current_user
      @submission.ignore_late_penalty = (submission_params[:ignore_late_penalty].to_i > 0)
      if submission_params[:created_at] and !@submission.ignore_late_penalty
        @submission.created_at = submission_params[:created_at]
      end
    else
      @submission.user = current_user
      @submission.ignore_late_penalty = false
    end


    self.send("create_#{@assignment.type.capitalize}")
  end

  def recreate_grade
    @grader = Grader.find(params[:grader_id])
    if @submission.recreate_missing_grade(@grader)
      @submission.compute_grade! if @submission.grade_complete?
      redirect_back fallback_location: course_assignment_submission_path(@course, @assignment, @submission)
    else
      redirect_back fallback_location: course_assignment_submission_path(@course, @assignment, @submission),
                    alert: "Grader already exists; use Regrade to modify it instead"
    end
  end

  def rerun_grader
    @grader = Grader.find(params[:grader_id])
    count = 0
    @assignment.used_submissions.each do |sub|
      @grader.grade(@assignment, sub)
      count += 1
    end
    redirect_back fallback_location: course_assignment_path(@course, @assignment),
                  notice: "Regraded #{@grader.display_type} for #{pluralize(count, 'submission')}"
  end

  def use_for_grading
    @submission.set_used_sub!
    redirect_back fallback_location: course_assignment_submission_path(@course, @assignment, @submission)
  end

  def rescind_lateness
    @submission.update_attribute(:ignore_late_penalty, true)
    @submission.compute_grade!
    redirect_back fallback_location: course_assignment_submission_path(@course, @assignment, @submission)
  end

  def edit_plagiarism
    @max_points = @assignment.graders.map(&:avail_score).sum
  end

  def update_plagiarism
    guilty_students = params.dig(:submission, :penalty)&.to_unsafe_h || {}
    guilty_students = guilty_students.map{|k, v| [k.to_i, v.to_f]}.to_h

    if guilty_students.empty?
      redirect_back fallback_location: edit_plagiarism_course_assignment_submission_path(@course, @assignment, @submission),
                    alert: "You haven't selected any students as being involved"
      return
    end
    comment = params[:comment]
    if comment.to_s.empty?
      redirect_back fallback_location: edit_plagiarism_course_assignment_submission_path(@course, @assignment, @submission),
                    alert: "Must leave some explanatory comment for the students"
      return
    end

    @max_points = @assignment.graders.map(&:avail_score).sum
    guilty_students.each do |id, penalty|
      penaltyPct = (100.0 * penalty.to_f) / @max_score.to_f
      student = User.find(id)
      sub = split_sub(@submission, student, [@submission.score.to_f - penaltyPct, 0].max)
      # Add the penalty comment
      sub_comment = InlineComment.new(
        submission: sub,
        label: "Plagiarism",
        line: 0,
        filename: sub.upload.extracted_path,
        grade_id: current_user.id,
        severity: "error",
        comment: comment,
        weight: penalty,
        suppressed: false,
        title: "",
        info: nil)
      sub_comment.save!
    end
    # Add a comment explaining the split
    sub_comment = InlineComment.new(
      submission: @submission,
      label: "Plagiarized submission",
      line: 0,
      filename: @submission.upload.extracted_path,
      grade_id: current_user.id,
      severity: "info",
      comment: "This submission has been reviewed for plagiarism and regraded accordingly.",
      weight: 0,
      suppressed: false,
      title: "",
      info: nil)
    sub_comment.save
    redirect_to course_assignment_path(@course, @assignment),
                notice: "Submission marked as plagiarized for #{guilty_students.map{|uid, _| User.find(uid).name}.join(', ')}"
  end

  def split_submission
    if @submission.users.count == 1
      redirect_back course_assignment_submission_path(@course, @assignment, @submission),
                    alert: "Submission is not a team-submission; no need to split it"
      return
    end
    @submission.users.each do |student|
      sub = split_sub(@submission, student)
      # Add a comment explaining the split
      sub_comment = InlineComment.new(
        submission: sub,
        label: "Split submission",
        line: 0,
        filename: sub.upload.extracted_path,
        grade_id: current_user.id,
        severity: "info",
        comment: "This is copied from a previous team submission, for individual grading",
        weight: 0,
        suppressed: false,
        title: "",
        info: nil)
      sub_comment.save!
    end
    # Add a comment explaining the split
    sub_comment = InlineComment.new(
      submission: @submission,
      label: "Split submission",
      line: 0,
      filename: @submission.upload.extracted_path,
      grade_id: current_user.id,
      severity: "info",
      comment: "This submission was split, to allow for individual grading",
      weight: 0,
      suppressed: false,
      title: "",
      info: nil)
    sub_comment.save!
    redirect_to course_assignment_path(@course, @assignment),
                notice: "Group submission split for #{@submission.users.map(&:name).join(', ')}"
  end

  def split_sub(orig_sub, for_user, score = nil)
    team = orig_sub.team
    if team
      # Construct a one-use team, so that this student can be graded in isolation
      team = Team.new(
        teamset_id: team.teamset_id,
        course: @course,
        start_date: orig_sub.created_at,
        end_date: orig_sub.created_at)
      team.users = [for_user]
      team.save
    end
    # Create the new submission, reusing the prior submitted file
    sub = Submission.new(
      assignment: @assignment,
      user: for_user,
      time_taken: orig_sub.time_taken,
      created_at: orig_sub.created_at,
      ignore_late_penalty: false,
      score: score || orig_sub.score,
      team: team,
      upload_id: @submission.upload_id,
      type: @submission.type)
    sub.save
    sub.set_used_sub!
    # Copy any grades
    orig_sub.grades.each do |g|
      new_g = g.dup
      new_g.submission = sub
      new_g.save
    end
    sub
  end

  def publish
    @submission.grades.where(score: nil).each do |g| g.grade(assignment, used) end
    @submission.grades.update_all(:available => true)
    @submission.compute_grade!
    redirect_back fallback_location: course_assignment_submission_path(@course, @assignment, @submission)
  end


  private

  def submission_params
    if true_user_prof_for?(@course) or current_user_prof_for?(@course)
      params[:submission].permit(:assignment_id, :user_id, :student_notes, :type,
                                 :auto_score, :calc_score, :created_at, :updated_at, :upload,
                                 :grading_output, :grading_uid, :team_id,
                                 :teacher_score, :teacher_notes,
                                 :ignore_late_penalty, :upload_file,
                                 :comments_upload_file, :time_taken)
    else
      params[:submission].permit(:assignment_id, :user_id, :student_notes, :type,
                                 :upload, :upload_file, :time_taken)
    end
  end

  def answers_params
    array_from_hash(params[:answers].to_unsafe_h)
  end

  def require_admin_or_staff
    unless current_user_site_admin? || current_user_staff_for?(@course)
      redirect_back fallback_location: course_assignment_submission_path(@course, @assignment, @submission),
                    alert: "Must be an admin or staff."
      return
    end
  end

  def require_admin_or_prof
    unless current_user_site_admin? || current_user_prof_for?(@course)
      redirect_back fallback_location: course_assignment_submission_path(@course, @assignment, @submission),
                    alert: "Must be an admin or professor."
      return
    end
  end

  def find_course_assignment
    @course = Course.find_by(id: params[:course_id])
    @assignment = Assignment.find_by(id: params[:assignment_id])
    if @course.nil?
      redirect_back fallback_location: root_path, alert: "No such course"
      return
    end
    if @assignment.nil? or @assignment.course_id != @course.id
      redirect_back fallback_location: course_path(@course), alert: "No such assignment for this course"
      return
    end
  end

  def find_submission
    @submission = Submission.find_by(id: params[:id])
    if @submission.nil?
      redirect_back fallback_location: course_assignment_path(params[:course_id], params[:assignment_id]),
                    alert: "No such submission"
      return
    end
    if @submission.assignment_id != @assignment.id
      redirect_back fallback_location: course_assignment_path(@course, @assignment), alert: "No such submission for this assignment"
      return
    end
  end


  ######################
  # Assignment types
  # NEW
  def new_Files
    render "new_#{@assignment.type.underscore}"
  end

  def new_Questions
    @questions = @assignment.questions
    @submission_dirs = []
    if @assignment.related_assignment
      related_sub = @assignment.related_assignment.used_sub_for(current_user)
      Audit.log("User #{current_user.id} (#{current_user.name}) is viewing the self-eval for assignment #{@assignment.related_assignment.id} and has agreed not to submit further files to it.\n")
      if related_sub.nil?
        @submission_files = []
      else
        get_submission_files(related_sub)
      end
    else
      @submission_files = []
    end
    render "new_#{@assignment.type.underscore}"
  end

  def new_Exam
    unless current_user_site_admin? || current_user_staff_for?(@course)
      redirect_back fallback_location: course_assignment_path(@course, @assignment),
                    alert: "Must be an admin or staff to enter exam grades."
      return
    end
    @grader = @assignment.graders.first
    redirect_to bulk_course_assignment_grader_path(@course, @assignment, @grader)
  end

  # CREATE
  def create_Files
    if (@submission.save_upload and @submission.save)
      @submission.set_used_sub!
      @submission.create_grades!
      @submission.autograde!
      path = course_assignment_submission_path(@course, @assignment, @submission)
      redirect_to(path, notice: 'Submission was successfully created.')
    else
      @submission.cleanup!
      new_Files
    end
  end

  def create_Questions
    @submission.answers = answers_params

    related_sub = @assignment.related_assignment.used_sub_for(@current_user)
    if related_sub.nil?
      @submission.related_files = []
    else
      @submission.related_files = get_submission_files(related_sub)
    end

    if @submission.save_upload && @submission.save
      @submission.set_used_sub!
      @submission.autograde!
      path = course_assignment_submission_path(@course, @assignment, @submission)
      redirect_to(path, notice: 'Response was successfully created.')
    else
      @submission.cleanup!
      new_Questions
    end
  end

  def create_Exam
    # No grades are created here, because we shouldn't ever get to this code
    # The grades are configured in the GradesController, in update_exam_grades
  end


  # SHOW
  def show_Files
    @gradesheet = Gradesheet.new(@assignment, [@submission])
    comments = @submission.grade_submission_comments(true) || {}
    comments = comments[@submission.upload.extracted_path.to_s] || []
    @plagiarized = comments.select{|c| c.label == "Plagiarism"}
    @split = comments.any?{|c| c.label == "Split submission"}
  end
  def show_Questions
    @gradesheet = Gradesheet.new(@assignment, [@submission])
    @questions = @assignment.questions
    @answers = YAML.load(File.open(@submission.upload.submission_path))
    @submission_dirs = []
    if @assignment.related_assignment
      @related_sub = @assignment.related_assignment.used_sub_for(@submission.user)
      if @related_sub.nil?
        @submission_files = []
        @answers_are_newer = true
      else
        get_submission_files(@related_sub)
        @answers_are_newer = (@related_sub.created_at < @submission.created_at)
      end
    else
      @submission_files = []
      @answers_are_newer = true
    end
    comments = @submission.grade_submission_comments(true) || {}
    comments = comments[@submission.upload.extracted_path.to_s] || []
    @plagiarized = comments.select{|c| c.label == "Plagiarism"}
    @split = comments.any?{|c| c.label == "Split submission"}
  end
  def show_Exam
    @student_info = @course.students.select(:username, :last_name, :first_name, :id)
    @grader = @assignment.graders.first
    @grade = Grade.find_by(grader_id: @grader.id, submission_id: @submission.id)
    @grade_comments = InlineComment.where(submission_id: @submission.id).order(:line).to_a
  end

  # DETAILS
  def details_Files
    respond_to do |f|
      f.html {
        get_submission_files(@submission, nil, true)
        render "details_#{@assignment.type.underscore}"
      }
      f.text {
        show_hidden = (current_user_site_admin? || current_user_staff_for?(@course))
        comments = @submission.grades
        unless show_hidden
          comments = comments.where(available: true)
        end
        comments = comments.map(&:inline_comments).flatten
        render plain: GradesController.pretty_print_comments(comments)
      }
    end
  end
  def details_Questions
    @questions = @assignment.questions
    @answers = YAML.load(File.open(@submission.upload.submission_path))
    if current_user_site_admin? || current_user_staff_for?(@course)
      @grades = @submission.inline_comments
    else
      @grades = @submission.visible_inline_comments
    end

    @show_grades = false

    @grades = @grades.select(:line, :name, :weight, :comment).joins(:user).sort_by(&:line).to_a
    @submission_dirs = []
    if @assignment.related_assignment
      @related_sub = @assignment.related_assignment.used_sub_for(@submission.user)
      if @related_sub.nil?
        @submission_files = []
        @answers_are_newer = true
      else
        get_submission_files(@related_sub)
        @answers_are_newer = (@related_sub.created_at < @submission.created_at)
      end
    else
      @submission_files = []
      @answers_are_newer = true
    end
    render "details_questions"
  end
  def details_Exam
    render "details_exam"
  end
end
