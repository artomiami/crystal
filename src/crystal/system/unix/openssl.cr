require "openssl"

module Crystal::System::Random

  def self.random_bytes(buf : Bytes) : Nil
      out = LibCrypto.rand_bytes(buf.to_unsafe.as(UInt8*), buf.size)
      if out != 1
        raise OpenSSL::Error.new("generating cryptographic rand_bytes failed")
      end
  end

  def self.next_u : UInt8
      buf = uninitialized UInt8[1]
      random_bytes(buf.to_slice)
      buf.unsafe_as(UInt8)
 end

end
