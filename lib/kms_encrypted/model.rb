module KmsEncrypted
  module Model
    def has_kms_key(legacy_key_id = nil, name: nil, key_id: nil, prefix: nil)
      key_id ||= legacy_key_id || ENV["KMS_KEY_ID"]

      key_method =
        if name
          "kms_key_#{name}"
        elsif prefix
          "#{prefix}_kms_key"
        else
          "kms_key"
        end

      class_eval do
        class << self
          def kms_keys
            @kms_keys ||= {}
          end unless respond_to?(:kms_keys)
        end
        kms_keys[key_method.to_sym] = {key_id: key_id}

        # same pattern as attr_encrypted reload
        if method_defined?(:reload) && kms_keys.size == 1
          alias_method :reload_without_kms_encrypted, :reload
          def reload(*args, &block)
            result = reload_without_kms_encrypted(*args, &block)
            self.class.kms_keys.keys.each do |key_method|
              instance_variable_set("@#{key_method}", nil)
            end
            result
          end
        end

        define_method(key_method) do
          raise ArgumentError, "Missing key id" unless key_id

          instance_var = "@#{key_method}"

          unless instance_variable_get(instance_var)
            key_column = "encrypted_#{key_method}"
            context_method =
              if name
                "kms_encryption_context_#{name}"
              elsif prefix
                "#{prefix}_kms_encryption_context"
              else
                "kms_encryption_context"
              end

            context = respond_to?(context_method, true) ? send(context_method) : {}
            default_encoding = "m"

            unless send(key_column)
              plaintext_key = nil
              encrypted_key = nil

              event = {
                key_id: key_id,
                context: context
              }
              ActiveSupport::Notifications.instrument("generate_data_key.kms_encrypted", event) do
                if key_id == "insecure-test-key"
                  plaintext_key = "00000000000000000000000000000000"
                  encrypted_key = "insecure-data-key-#{rand(1_000_000_000_000)}"
                elsif key_id.start_with?("projects/")
                  # generate random AES-256 key
                  plaintext_key = OpenSSL::Random.random_bytes(32)

                  # encrypt it
                  # load client first to ensure namespace is loaded
                  client = KmsEncrypted.google_client
                  request = ::Google::Apis::CloudkmsV1::EncryptRequest.new(
                    plaintext: plaintext_key,
                    additional_authenticated_data: context.to_json
                  )
                  response = client.encrypt_crypto_key(key_id, request)
                  key_version = response.name

                  # shorten key to save space
                  short_key_id = Base64.encode64(key_version.split("/").select.with_index { |_, i| i.odd? }.join("/"))

                  # build encrypted key
                  # we reference the key in the field for easy rotation
                  encrypted_key = "$gc$#{short_key_id}$#{[response.ciphertext].pack(default_encoding)}"
                elsif key_id.start_with?("vault/")
                  # generate random AES-256 key
                  plaintext_key = OpenSSL::Random.random_bytes(32)

                  # encrypt it
                  response = KmsEncrypted.vault_client.logical.write(
                    "transit/encrypt/#{key_id.sub("vault/", "")}",
                    plaintext: Base64.encode64(plaintext_key),
                    context: Base64.encode64(context.to_json)
                  )

                  encrypted_key = response.data[:ciphertext]
                else
                  # generate data key from API
                  resp = KmsEncrypted.aws_client.generate_data_key(
                    key_id: key_id,
                    encryption_context: context,
                    key_spec: "AES_256"
                  )
                  plaintext_key = resp.plaintext
                  encrypted_key = [resp.ciphertext_blob].pack(default_encoding)
                end
              end

              instance_variable_set(instance_var, plaintext_key)
              self.send("#{key_column}=", encrypted_key)
            end

            unless instance_variable_get(instance_var)
              encrypted_key = send(key_column)
              plaintext_key = nil

              event = {
                key_id: key_id,
                context: context
              }
              ActiveSupport::Notifications.instrument("decrypt_data_key.kms_encrypted", event) do
                if encrypted_key.start_with?("insecure-data-key-")
                  plaintext_key = "00000000000000000000000000000000".encode("BINARY")
                elsif encrypted_key.start_with?("$gc$")
                  _, _, short_key_id, ciphertext = encrypted_key.split("$", 4)

                  # restore key, except for cryptoKeyVersion
                  stored_key_id = Base64.decode64(short_key_id).split("/")[0..3]
                  stored_key_id.insert(0, "projects")
                  stored_key_id.insert(2, "locations")
                  stored_key_id.insert(4, "keyRings")
                  stored_key_id.insert(6, "cryptoKeys")
                  stored_key_id = stored_key_id.join("/")

                  # load client first to ensure namespace is loaded
                  client = KmsEncrypted.google_client
                  request = ::Google::Apis::CloudkmsV1::DecryptRequest.new(
                    ciphertext: ciphertext.unpack(default_encoding).first,
                    additional_authenticated_data: context.to_json
                  )
                  plaintext_key = client.decrypt_crypto_key(stored_key_id, request).plaintext
                elsif encrypted_key.start_with?("vault:")
                  response = KmsEncrypted.vault_client.logical.write(
                    "transit/decrypt/#{key_id.sub("vault/", "")}",
                    ciphertext: encrypted_key,
                    context: Base64.encode64(context.to_json)
                  )

                  plaintext_key = Base64.decode64(response.data[:plaintext])
                else
                  plaintext_key = KmsEncrypted.aws_client.decrypt(
                    ciphertext_blob: encrypted_key.unpack(default_encoding).first,
                    encryption_context: context
                  ).plaintext
                end
              end

              instance_variable_set(instance_var, plaintext_key)
            end
          end

          instance_variable_get(instance_var)
        end

        define_method("rotate_#{key_method}!") do
          # decrypt
          plaintext_attributes = {}
          self.class.encrypted_attributes.select { |_, v| v[:key] == key_method.to_sym }.keys.each do |key|
            plaintext_attributes[key] = send(key)
          end

          # reset key
          instance_variable_set("@#{key_method}", nil)
          send("encrypted_#{key_method}=", nil)

          # encrypt again
          plaintext_attributes.each do |attr, value|
            send("#{attr}=", value)
          end

          # update atomically
          save!
        end
      end
    end
  end
end
