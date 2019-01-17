class AddCustomNameToGraders < ActiveRecord::Migration[5.2]
  def change
    add_column :graders, :custom_name, :string
  end
end
