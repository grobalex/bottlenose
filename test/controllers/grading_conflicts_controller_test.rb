require 'test_helper'

class GradingConflictsControllerTest < ActionDispatch::IntegrationTest
  test "should get index" do
    get grading_conflicts_index_url
    assert_response :success
  end

end
