class GradingConflictsController < ApplicationController
	layout 'course'

	before_action :find_course
	before_action :require_registered_user

	def edit
		@conflicts = @course.grading_conflicts
		list_of_conflict = @conflicts.where(staff_user_id: current_user.id).pluck(:student_user_id)
		if list_of_conflict.nil?
			@students = @course.students.sort_by(&:sort_name)
		else
			@students = @course.students.sort_by(&:sort_name).keep_if{|student| list_of_conflict.exclude? student.id }
		end
		@staff = @course.staff.sort_by(&:sort_name).keep_if{|staff| @course.professors.exclude? staff  }
		if current_user.site_admin?
			@role = "professor"
		else
			@role = current_user.registration_for(@course).role
		end
	end

	def update
		@cur_role = (current_user_site_admin? ? "professor" : @registration&.role)
		if @cur_role != "professor"
			if params[:students_id].nil?
				redirect_back(fallback_location: root_path,
				 alert: "You must select at least one student to submit a conflict")
			else	
				params[:students_id].each do |student_id|
					conflict = GradingConflict.find_or_create_by(course_id: params[:course_id], staff_user_id: params[:staff_id], student_user_id: student_id)
					conflict.save
				end
				redirect_back(fallback_location: root_path,
				 notice: "Conflicts saved")
			end	
		elsif @cur_role == "professor"
			if(params.has_key?(:id))
				respond_to do |f|
					f.json {
						GradingConflict.destroy(params[:id])
						render :json => {Success: "Deleted"}, status: 200
						return		
					}
				end
			else
				find_conflict = GradingConflict.find_by(course_id: params[:course_id], staff_user_id: params[:staff_id], student_user_id: params[:students_id])
       			if find_conflict.nil?
	       			conflict = GradingConflict.new(course_id: params[:course_id], staff_user_id: params[:staff_id], student_user_id: params[:students_id])
					conflict.save
					redirect_back(fallback_location: root_path, notice: "Conflicts saved")
				else
					redirect_back(fallback_location: root_path, alert: "Conflict already exists")
				end
			end
		end
	end	
end