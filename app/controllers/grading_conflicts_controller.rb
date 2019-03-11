class GradingConflictsController < ApplicationController
	layout 'course'

	before_action :find_course
	before_action :require_registered_user
	before_action :require_admin_or_staff

	def edit
		@role = (current_user_site_admin? ? "professor" : @registration&.role)
		if @role  == "professor" 
			@staff = @course.staff.sort_by(&:sort_name).keep_if{|staff| @course.professors.exclude? staff  }
			@conflicts = @course.grading_conflicts.sort_by(&:staff_user_id)
			@students = @course.students.sort_by(&:sort_name)
		else
			@conflicts = @course.grading_conflicts.where(staff_user_id: current_user.id)
			list_of_conflict = @conflicts.pluck(:student_user_id)
			if list_of_conflict.nil?
				@students = @course.students.sort_by(&:sort_name)
			else
				@students = @course.students.sort_by(&:sort_name).keep_if{|student| list_of_conflict.exclude? student.id }
			end
		end
	end

	def update
		no_errors = true
		@cur_role = (current_user_site_admin? ? "professor" : @registration&.role)
		if @cur_role == "assistant" || @cur_role == "grader"
			if params[:students_id].nil?
				redirect_back(fallback_location: root_path,
					alert: "You must select at least one student to submit a conflict")
			else
				params[:students_id].each do |student_id|
					response = create_conflict(params[:course_id], current_user.id, student_id)
					no_errors = response & no_errors
				end
				if no_errors 
					redirect_back(fallback_location: root_path, notice: "Successfully created")
				else
					redirect_back(fallback_location: root_path,  alert: "Conflict could not be saved")
				end

			end
		elsif @cur_role == "professor"
			if(params.has_key?(:id))
				respond_to do |f|
					f.json {
						GradingConflict.destroy(params[:id])
						render :json => {Success: "Deleted"}, status: 200		
					}
				end
			else
				response = create_conflict(params[:course_id],  params[:staff_id], params[:students_id])
				if response 
					redirect_back(fallback_location: root_path, notice: "Successfully created")
				else
					redirect_back(fallback_location: root_path,  alert: "Conflict already exists")
				end
			end
		end
	end	
	
	protected

	def create_conflict(course_id, staff_id, student_id)
		find_conflict = GradingConflict.find_by(course_id: course_id, staff_user_id: staff_id, student_user_id: student_id)
		if find_conflict.nil?
			GradingConflict.transaction do
				conflict = GradingConflict.new(course_id: course_id, staff_user_id: staff_id, student_user_id: student_id)
				conflict.save!
			end
			true
		else
			false
		end
	end

	def validate_params
		return true unless params.has_key?(:students_id)
		@course.students.all? { |i| params[:students_id].include?(i.id.to_s) }
	end
end	