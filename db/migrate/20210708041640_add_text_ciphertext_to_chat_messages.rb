class AddTextCiphertextToChatMessages < ActiveRecord::Migration[6.0]
  def change
    add_column :chat_messages, :text_ciphertext, :text
  end
end
