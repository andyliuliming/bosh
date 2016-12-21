Sequel.migration do
  up do
    create_table(:director_attributes) do
      if Sequel::Model.db.database_type == :mssql
        String :uuid, null: false, primary_key: true
      else
        String :uuid, unique: true, null: false, primary_key: true
      end
    end
  end

  down do
    drop_table(:director_attributes)
  end

end
