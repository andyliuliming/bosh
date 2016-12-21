Sequel.migration do
  change do
    if [:mssql].include?(database_type)
        run <<-SQL
          DECLARE @table NVARCHAR(512), @dropconstraintsql NVARCHAR(MAX);
          SELECT @table = N'events';
          SELECT @dropconstraintsql = 'ALTER TABLE ' + @table
              + ' DROP CONSTRAINT ' + name + ';'
              FROM sys.key_constraints
              WHERE [type] = 'PK'
              AND [parent_object_id] = OBJECT_ID(@table);

          EXEC sp_executeSQL @dropconstraintsql
          SQL
        alter_table :events do
          set_column_type :id, Bignum
          set_column_type :parent_id, Bignum
          add_primary_key [:id]
        end
    else
      unless [:sqlite].include?(adapter_scheme)
        set_column_type :events, :id, Bignum
        set_column_type :events, :parent_id, Bignum
      end
    end
  end
end
