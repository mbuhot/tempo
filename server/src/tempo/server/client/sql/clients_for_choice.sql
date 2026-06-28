-- clients_for_choice.sql — all current clients for the project-creation picker.
SELECT id::integer, name::text FROM client_current ORDER BY name;
