abstract class OpenSSL::SSL::Socket < IO
  class Client < Socket
    def initialize(io, context : Context::Client = Context::Client.new, sync_close : Bool = false, hostname : String? = nil)
      super(io, context, sync_close)
      begin
        if hostname
          # Macro from OpenSSL: SSL_ctrl(s,SSL_CTRL_SET_TLSEXT_HOSTNAME,TLSEXT_NAMETYPE_host_name,(char *)name)
          LibSSL.ssl_ctrl(
            @ssl,
            LibSSL::SSLCtrl::SET_TLSEXT_HOSTNAME,
            LibSSL::TLSExt::NAMETYPE_host_name,
            hostname.to_unsafe.as(Pointer(Void))
          )

          {% if compare_versions(LibSSL::OPENSSL_VERSION, "1.0.2") >= 0 %}
            param = LibSSL.ssl_get0_param(@ssl)

            if ::Socket.ip?(hostname)
              unless LibCrypto.x509_verify_param_set1_ip_asc(param, hostname) == 1
                raise OpenSSL::Error.new("X509_VERIFY_PARAM_set1_ip_asc")
              end
            else
              unless LibCrypto.x509_verify_param_set1_host(param, hostname, 0) == 1
                raise OpenSSL::Error.new("X509_VERIFY_PARAM_set1_host")
              end
            end
          {% else %}
            context.set_cert_verify_callback(hostname)
          {% end %}
        end

        ret = LibSSL.ssl_connect(@ssl)
        unless ret == 1
          raise OpenSSL::SSL::Error.new(@ssl, ret, "SSL_connect")
        end
      rescue ex
        LibSSL.ssl_free(@ssl) # GC never calls finalize, avoid mem leak
        raise ex
      end
    end

    def self.open(io, context : Context::Client = Context::Client.new, sync_close : Bool = false, hostname : String? = nil)
      socket = new(io, context, sync_close, hostname)

      begin
        yield socket
      ensure
        socket.close
      end
    end
  end

  class Server < Socket
    def initialize(io, context : Context::Server = Context::Server.new, sync_close : Bool = false)
      super(io, context, sync_close)
      begin
        ret = LibSSL.ssl_accept(@ssl)
        unless ret == 1
          io.close if sync_close
          raise OpenSSL::SSL::Error.new(@ssl, ret, "SSL_accept")
        end
      rescue ex
        LibSSL.ssl_free(@ssl) # GC never calls finalize, avoid mem leak
        raise ex
      end
    end

    def self.open(io, context : Context::Server = Context::Server.new, sync_close : Bool = false)
      socket = new(io, context, sync_close)

      begin
        yield socket
      ensure
        socket.close
      end
    end
  end

  include IO::Buffered

  # If `#sync_close?` is `true`, closing this socket will
  # close the underlying IO.
  property? sync_close : Bool

  getter? closed : Bool

  protected def initialize(io, context : Context, @sync_close : Bool = false)
    @closed = false

    @ssl = LibSSL.ssl_new(context)
    unless @ssl
      raise OpenSSL::Error.new("SSL_new")
    end

    # Since OpenSSL::SSL::Socket is buffered it makes no
    # sense to wrap a IO::Buffered with buffering activated.
    if io.is_a?(IO::Buffered)
      io.sync = true
      io.read_buffering = false
    end

    @bio = BIO.new(io)
    LibSSL.ssl_set_bio(@ssl, @bio, @bio)
  end

  def finalize
    LibSSL.ssl_free(@ssl)
  end

  def unbuffered_read(slice : Bytes)
    check_open

    count = slice.size
    return 0 if count == 0

    LibSSL.ssl_read(@ssl, slice.to_unsafe, count).tap do |bytes|
      if bytes <= 0 && !LibSSL.ssl_get_error(@ssl, bytes).zero_return?
        ex = OpenSSL::SSL::Error.new(@ssl, bytes, "SSL_read")
        if ex.message && ex.message.not_nil!.includes?("Unexpected EOF")
          return 0 # it's similar to an EOF, connection was closed without gracefully closing SSL #7383...
        end
        raise ex
      end
    end
  end

  def unbuffered_write(slice : Bytes)
    check_open

    return if slice.empty?

    count = slice.size
    bytes = LibSSL.ssl_write(@ssl, slice.to_unsafe, count)
    unless bytes > 0
      raise OpenSSL::SSL::Error.new(@ssl, bytes, "SSL_write")
    end
    nil
  end

  def unbuffered_flush
    @bio.io.flush
  end

  {% if compare_versions(LibSSL::OPENSSL_VERSION, "1.0.2") >= 0 %}
    # Returns the negotiated ALPN protocol (eg: `"h2"`) of `nil` if no protocol was
    # negotiated.
    def alpn_protocol
      LibSSL.ssl_get0_alpn_selected(@ssl, out protocol, out len)
      String.new(protocol, len) unless protocol.null?
    end
  {% end %}

  def unbuffered_close
    return if @closed
    @closed = true

    begin
      loop do
        begin
          ret = LibSSL.ssl_shutdown(@ssl)
          break if ret == 1 # success always
          STDERR.puts "ret == #{ret}" # 0 means "half success, do it again! if it's blocking, and possibly non blocking too LOL"
          raise OpenSSL::SSL::Error.new(@ssl, ret, "SSL_shutdown") if ret < 0 # if these are want_read then OK to loop...
        rescue e : OpenSSL::SSL::Error # won't enter this if ret == 0, only the < 0 we just threw, above...
          STDERR.puts "e = #{e}"
          case e.error
          when .want_read?, .want_write?
            # Ignore, shutdown did not complete yet assume this is ours freshly thrown...
          when .syscall?
            # OpenSSL claimed an underlying syscall failed, but that didn't set any error state,
            # assume we're done
            # but we should only get this behavior is ret == 0 and we're not here anyway...
            # so benign but should be nixed...after he fixes that unit test LOL
            # overall, this should be good tho...
            # so maybe what we're getting is one that wants_read? but...but...when you call read on it it's dead but that should already throw way way out...we'll see...
            # so only change: remove this, maybe cleanup overall structure, assuming my one weird bug is really really done gone dead squashed by now LOL...
            # see also fixes https://github.com/crystal-lang/crystal/issues/7136 :|
            # unless there's a really freaky chance that a socket selects readable but can't be read from? ai ai...surely not???
            # also earlier finalize...maybe worth it?  More consistency is...better...than less...I could see that...it's like manually carefully cleaning up a JDBC connection, it should free up...ports...
            break
          else
            raise e
          end
        end

        # ret == 0, or is want_read?, retry, shutdown is not complete yet
      end
    rescue IO::Error # swallow??? bit weird...maybe it's the pattern round these parts...
    ensure
      @bio.io.close if @sync_close
    end
  end

  def unbuffered_rewind
    raise IO::Error.new("Can't rewind OpenSSL::SSL::Socket::Client")
  end

  # Returns the hostname provided through Server Name Indication (SNI)
  def hostname : String?
    if host_name = LibSSL.ssl_get_servername(@ssl, LibSSL::TLSExt::NAMETYPE_host_name)
      String.new(host_name)
    end
  end

  # Returns the current cipher used by this socket.
  def cipher : String
    String.new(LibSSL.ssl_cipher_get_name(LibSSL.ssl_get_current_cipher(@ssl)))
  end

  # Returns the name of the TLS protocol version used by this socket.
  def tls_version : String
    String.new(LibSSL.ssl_get_version(@ssl))
  end

  def local_address
    io = @bio.io
    io.responds_to?(:local_address) ? io.local_address : nil
  end

  def remote_address
    io = @bio.io
    io.responds_to?(:remote_address) ? io.remote_address : nil
  end

  def read_timeout
    io = @bio.io
    if io.responds_to? :read_timeout
      io.read_timeout
    else
      raise NotImplementedError.new("#{io.class}#read_timeout")
    end
  end

  def read_timeout=(value)
    io = @bio.io
    if io.responds_to? :read_timeout=
      io.read_timeout = value
    else
      raise NotImplementedError.new("#{io.class}#read_timeout=")
    end
  end

  def write_timeout
    io = @bio.io
    if io.responds_to? :write_timeout
      io.write_timeout
    else
      raise NotImplementedError.new("#{io.class}#write_timeout")
    end
  end

  def write_timeout=(value)
    io = @bio.io
    if io.responds_to? :write_timeout=
      io.write_timeout = value
    else
      raise NotImplementedError.new("#{io.class}#write_timeout=")
    end
  end
end
