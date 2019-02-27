class GradingConflict < ApplicationRecord

	belongs_to :staff_user, class_name: "User"
	belongs_to :student_user, class_name: "User"
	belongs_to :course
end	