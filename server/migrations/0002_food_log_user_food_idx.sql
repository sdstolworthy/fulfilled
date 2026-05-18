-- no-transaction
CREATE INDEX CONCURRENTLY log_user_food_idx
    ON food_log_entries(user_id, food_id);
