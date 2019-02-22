class GradingConflictsController < ApplicationController

	before_action :find_course
	before_action :require_registered_user

	def edit
		@conflicts = @course.grading_conflicts
		p @conflicts
		@students = @course.students.sort_by(&:sort_name).keep_if{|student| @conflicts.exclude? student.id }
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
				redirect_back(fallback_location: root_path)
			else	
				params[:students_id].each do |student_id|
					p params
					conflict = GradingConflict.create(course_id: params[:course_id], staff_user_id: params[:staff_id], student_user_id: student_id)
					conflict.save
				end
				redirect_back(fallback_location: root_path)
			end	
		else
			respond_to do |f|
				f.json {
					@conflict = GradingConflict.find_by(id: params[:id])
       				 if @conflict.nil?
       				 	conflict = GradingConflict.create(course_id: params[:course_id], staff_user_id: params[:staff_id], student_user_id: student_id)
						conflict.save
						render :json => {Success: "Added"}, status: 200
						return	

					else
						GradingConflict.destroy(params[:id])
						render :json => {Success: "Deleted"}, status: 200
						return
					end			
				}
			end	
		end
	end	
end