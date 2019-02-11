class GradingConflictsController < ApplicationController

  before_action :find_course
  before_action :require_registered_user
 
  def index
  	@students = @course.students
    @staff = @course.staff
    if current_user.site_admin?
      @role = "professor"
    else
      @role = current_user.registration_for(@course).role
    end
  end

  def new
  end

  def update
  end

end