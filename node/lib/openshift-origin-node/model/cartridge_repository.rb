#--
# Copyright 2013 Red Hat, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#++

=begin
Cartridge Repository--

* 1 per Node
* Index used by Node to find cartridges to install
* A cartridge version can only safely be removed from the Repository
  if it is not being used in any gear. A new version will only impact
  new instances of the cartridge being installed.
  * A cartridge instance is updated to a new version by:
    - remove old version/add new version from the gear
    - migration, compatible change old to new
    - migration/setup, incompatible change old to new

* Default software version is greatest Version element
* Default cartridge version is greatest Cartridge-Version element

In-Memory Index (missing keys will assume default)
{cartridge name}, {software version}, {cartridge version} -> Cartridge obj

Cartridge Repository (1 per Node)
CARTRIDGE_REPO_DIR/{cartridge vendor}-{cartridge name}
    +- {cartridge version 0}
    |  +- metadata
    |  |  +- manifest.yml
    |  +- ...(file tree)
    +- {cartridge version 1}
    |  +- metadata
    |  |  +- manifest.yml
    |  +- ... (file tree)
    +- {cartridge version 2}
    |  +- ...


Gear
GEAR_BASE_DIR/{cartridge vendor}-{cartridge name}
    +- metadata
    |  +- manifest.yml
    +- ... (file tree)
GEAR_BASE_DIR/local-{custom cartridge name}
    +- metadata
    |  +- manifest.yml
    +- ... (file tree)
=end

require 'openshift-origin-node/utils/path_utils'
require 'openshift-origin-node/utils/shell_exec'
require 'openshift-origin-node/utils/node_logger'
require 'openshift-origin-node/model/cartridge'
require 'pathname'
require 'singleton'
require 'thread'
require 'open-uri'
require 'uri'
require 'rubygems/package'

module OpenShift

  # Singleton to provide management of cartridges installed on the system
  #
  class CartridgeRepository
    include Singleton
    include NodeLogger
    include Enumerable

    #FIXME: move to node.conf
    CARTRIDGE_REPO_DIR = '/var/lib/openshift/.cartridge_repository'

    # Filesystem path to where cartridges are installed
    attr_reader :path

    def initialize # :nodoc:
      @semaphore = Mutex.new
      @path      = CARTRIDGE_REPO_DIR

      FileUtils.mkpath(@path) unless File.exist? @path
      clear
      load @path
    end

    # :call-seq:
    #   CartridgeRepository.instance.clear -> nil
    #
    # Clear all entries from the memory index. Nothing is removed from the disk.
    #
    #   CartridgeRepository.instance.clear #=> nil
    def clear
      @index = Hash.new { |h, k| h[k] = Hash.new(&h.default_proc) }
    end

    # :call-seq:
    #   CartridgeRepository.instance.size -> Fixnum
    #
    # number of cartridges in repository
    #
    #   CartridgeRepository.instance.size   #=> 24
    def size
      @index.keys.uniq.count
    end

    # :call-seq:
    #   CartridgeRepository.instance.load([directory path]) -> Fixnum
    #
    # Read cartridge manifests from the CARTRIDGE_REPO_DIR or the provided +directory+.
    #
    #   CartridgeRepository.instance.load("/var/lib/openshift/.cartridge_repository")  #=> 24
    def load(directory = nil)
      @semaphore.synchronize do
        find_manifests(directory || @path) do |manifest_path|
          c = insert(OpenShift::Runtime::Cartridge.new(manifest_path, nil, @path))
          logger.debug { "Loaded cartridge (#{c.name}, #{c.version}, #{c.cartridge_version}) from #{manifest_path}" }
        end
      end

      size
    end

    # :call-seq:
    #   CartridgeRepository.instance.select(cartridge_name)                             -> Cartridge
    #   CartridgeRepository.instance.select(cartridge_name, version)                    -> Cartridge
    #   CartridgeRepository.instance.select(cartridge_name, version, cartridge_version) -> Cartridge
    #   CartridgeRepository.instance[cartridge_name]                                    -> Cartridge
    #   CartridgeRepository.instance[cartridge_name, version]                           -> Cartridge
    #   CartridgeRepository.instance[cartridge_name, version, cartridge_version]        -> Cartridge
    #
    # Select a cartridge from repository
    #
    # Each version parameter you provide narrows the search to the exact revision of the Cartridge you are requesting.
    # If you do not provide _cartridge_version_ then the latest is assumed, for _version_ and _cartridge_name_.
    # If you do not provide _cartridge_version_ and _version_, then the latest _cartridge_name_ will be returned.
    #
    # Latest is determined from the _Version_ elements provided in the cartridge's manifest, when the cartridge is
    # loaded.
    #
    # Assuming PHP, 3.5 and 0.1 are all the latest each of these calls would return the same cartridge.
    #   CartridgeRepository.instance.select('php', '3.5', '0.1')  #=> Cartridge
    #   CartridgeRepository.instance.select('php', '3.5')         #=> Cartridge
    #   CartridgeRepository.instance.select('php')                #=> Cartridge
    #   CartridgeRepository.instance['php', '3.5', '0.1']         #=> Cartridge
    #   CartridgeRepository.instance['php', '3.5']                #=> Cartridge
    #   CartridgeRepository.instance['php']                       #=> Cartridge
                    #
    def select(cartridge_name, version = nil, cartridge_version = nil)
      unless exist?(cartridge_name, cartridge_version, version)
        raise KeyError.new("key not found: (#{cartridge_name}, #{version}, #{cartridge_version})")
      end

      @index[cartridge_name][version][cartridge_version]
    end

    alias [] select # :nodoc:

    # :call-seq:
    #   CartridgeRepository.instance.install(directory) -> Cartridge
    #
    # Copies a cartridge's source into the cartridge repository from a +directory+. The Cartridge will additionally
    # be indexed and available from a CartridgeRepository.instance
    #
    #   CartridgeRepository.instance.install('/usr/libexec/openshift/v2/cartridges/openshift-origin-php')  #=> Cartridge
    def install(directory)
      raise ArgumentError.new("Illegal path to cartridge source: '#{directory}'") unless directory && File.directory?(directory)
      raise ArgumentError.new("Source cannot be: '#{@path}'") if directory == @path

      manifest_path = PathUtils.join(directory, 'metadata', 'manifest.yml')
      raise ArgumentError.new("Cartridge manifest.yml missing: '#{manifest_path}'") unless File.file?(manifest_path)

      entry = nil
      @semaphore.synchronize do
        entry = insert(OpenShift::Runtime::Cartridge.new(manifest_path, nil, @path))

        FileUtils.rm_r(entry.repository_path) if File.exist?(entry.repository_path)
        FileUtils.mkpath(entry.repository_path)

        Utils.oo_spawn("shopt -s dotglob; /bin/cp -ad #{directory}/* #{entry.repository_path}",
                       expected_exitstatus: 0)
      end
      entry
    end

    # :call-seq:
    #   CartridgeRepository.instance.erase(cartridge_name, version, cartridge_version) -> Cartridge
    #
    # Erase given version of a cartridge from the cartridge repository and remove from index. This cannot be undone.
    #
    #   CartridgeRepository.instance.erase('php', '3.5', '1.0') #=> Cartridge
    def erase(cartridge_name, version, cartridge_version)
      unless exist?(cartridge_name, cartridge_version, version)
        raise KeyError.new("key not found: (#{cartridge_name}, #{version}, #{cartridge_version})")
      end

      entry = nil
      @semaphore.synchronize do
        # find a "template" entry
        entry = select(cartridge_name, version, cartridge_version)

        # Now go back and find all occurrences of the "template"
        @index[cartridge_name].each_key do |k2|
          @index[cartridge_name][k2].each_pair do |k3, v3|
            if v3.eql?(entry)
              remove(cartridge_name, k2, k3)
            end
          end
        end

        FileUtils.rm_r(entry.repository_path)
        parent = Pathname.new(entry.repository_path).parent
        FileUtils.rm_r(parent) if 0 == parent.children.count
      end

      entry
    end

    # :call-seq:
    #   CartridgeRepository.instance.exists?(cartridge_name, cartridge_version, version)  -> true or false
    #
    # Is there an entry in the repository for this tuple?
    #
    #   CartridgeRepository.instance.erase('cobol', '2002', '1.0') #=> false
    def exist?(cartridge_name, cartridge_version, version)
      @index.key?(cartridge_name) &&
          @index[cartridge_name].key?(version) &&
          @index[cartridge_name][version].key?(cartridge_version)
    end

    # :call-seq:
    #   CartridgeRepository.instance.find_manifests(directory)
    #
    # Search the cartridge repository +directory+ sub-directories for cartridge manifest files
    #
    #   CartridgeRepository.instance.find_manifests(directory)
    def find_manifests(directory) # :nodoc: :yield: pathname
      raise ArgumentError.new("Illegal path to cartridge repository: '#{directory}'") unless File.directory?(directory)

      # wildcards: cartridges and cartridge versions
      glob = PathUtils.join(directory, '*', '*', 'metadata', 'manifest.yml')
      Dir[glob].each { |e| yield e }
    end

    # :call-seq:
    #   CartridgeRepository.instance.remove(cartridge_name, version, cartridge_version) -> Cartridge
    #
    # Remove index entry for this tuple
    #
    #   CartridgeRepository.instance.remove('php', '5.3', '1.0') -> Cartridge
    def remove(cartridge_name, version, cartridge_version) # :nodoc:
      @index[cartridge_name][version].delete(cartridge_version)
      @index[cartridge_name].delete(version) if  @index[cartridge_name][version].empty?
      @index.delete(cartridge_name) if  @index[cartridge_name].empty?
    end


    # :call-seq:
    #   CartridgeRepository.instance.insert(cartridge) -> Cartridge
    #
    # Insert cartridge into index
    #
    #   CartridgeRepository.instance.instance(cartridge) -> Cartridge
    def insert(cartridge) # :nodoc:
      cartridge.versions.each do |version|
        @index[cartridge.name][version][cartridge.cartridge_version] = cartridge
        @index[cartridge.name][version][nil]                         = cartridge
        @index[cartridge.name][nil][nil]                             = cartridge
      end

      cartridge
    end

    # :call-seq:
    #   CartridgeRepository.instance.each -> Cartridge
    #
    # Process each unique cartridge
    #
    #   CartridgeRepository.instance.each {|c| puts c.name}
    def each
      cartridges = []
      # @index.values returned nothing...
      @index.each_pair do |_, sw_hash|
        sw_hash.each_pair do |sw_ver, cart_hash|
          next unless sw_ver
          cart_hash.each_pair do |cart_ver, cartridge|
            next unless cart_ver
            cartridges.push cartridge
          end
        end
      end

      cartridges.uniq.each { |c| yield c }
    end

    ## print out all indexed cartridges in a table
    def to_s
      @index.inject("<CartridgeRepository:\n") do |memo, (name, sw_hash)|
        sw_hash.inject(memo) do |memo, (sw_ver, cart_hash)|
          cart_hash.inject(memo) do |memo, (cart_ver, cartridge)|
            memo << "(#{name}, #{sw_ver}, #{cart_ver}): " << cartridge.to_s << "\n"
          end
        end
      end << '>'
    end

    # :call-seq:
    #   CartridgeRepository.instantiate_cartridge(cartridge, path) -> nil
    #
    # Instantiate a cartridge in a gear;
    #   If the cartridge manifest_path is :url then source_url is used to obtain cartridge source
    #   Otherwise the cartridge source is copied from the cartridge_repository
    #
    #   source_hash is used to ensure the download was successful.
    #
    #   CartridgeRepository.instantiate_cartridge(perl_cartridge, '/var/lib/.../mock') => nil
    def self.instantiate_cartridge(cartridge, target)
      FileUtils.mkpath target

      if :url == cartridge.manifest_path
        uri       = URI(cartridge.source_url)
        temporary = PathUtils.join(File.dirname(target), File.basename(cartridge.source_url))

        case
          when 'git' == uri.scheme || cartridge.source_url.end_with?('.git')
            Utils::oo_spawn(%Q(set -xe;
                               git clone #{cartridge.source_url} #{cartridge.name};
                               GIT_DIR=./#{cartridge.name}/.git git repack),
                            chdir:               Pathname.new(target).parent.to_path,
                            expected_exitstatus: 0)

          when uri.scheme =~ /^https*/ && cartridge.source_url =~ /\.zip/
            begin
              uri_copy(URI(cartridge.source_url), temporary, cartridge.source_md5)
              extract(:zip, temporary, target)
            ensure
              FileUtils.rm(temporary)
            end

          when uri.scheme =~ /^https*/ && cartridge.source_url =~ /(\.tar\.gz|\.tgz)$/
            begin
              uri_copy(URI(cartridge.source_url), temporary, cartridge.source_md5)
              extract(:tgz, temporary, target)
            ensure
              FileUtils.rm(temporary)
            end

          when uri.scheme =~ /^https*/ && cartridge.source_url =~ /\.tar$/
            begin
              uri_copy(URI(cartridge.source_url), temporary, cartridge.source_md5)
              extract(:tar, temporary, target)
            ensure
              FileUtils.rm(temporary)
            end

          when 'file' == uri.scheme
            entries = Dir.glob(PathUtils.join(uri.path, '*'), File::FNM_DOTMATCH)
            filesystem_copy(entries, target, %w(. ..))

          else
            raise ArgumentError.new("Unsupported URL(#{cartridge.source_url}) for downloading a private cartridge")
        end
      else
        entries = Dir.glob(PathUtils.join(cartridge.repository_path, '*'), File::FNM_DOTMATCH)
        filesystem_copy(entries, target, %w(. .. usr))

        usr_path = File.join(cartridge.repository_path, 'usr')
        FileUtils.symlink(usr_path, File.join(target, 'usr')) if File.exist? usr_path
      end

      valid_cartridge_home(cartridge, target)
    rescue
      FileUtils.rm_rf target
      raise
    end

    private

    def self.uri_copy(uri, temporary, md5 = nil)
      File.open(temporary, 'w') do |output|
        uri.open do |input|
          begin
            while true
              partial = input.readpartial(4096)
              output.write partial
            end
          rescue EOFError
            # we are done
          end
        end
      end

      if md5
        digest = Digest::MD5.file(temporary).hexdigest
        raise IOError.new(
                  "Failed to download cartridge, checksum failed: #{md5} expected, #{digest} actual"
              ) if digest != md5
      end
    end

    def self.filesystem_copy(entries, target, black_list)
      entries.delete_if do |e|
        black_list.include? File.basename(e)
      end

      raise ArgumentError.new('No cartridge sources found to install.') if entries.empty?

      Utils.oo_spawn("/bin/cp -ad #{entries.join(' ')} #{target}",
                     expected_exitstatus: 0)
    end

    def self.extract(method, source, target)
      case method
        when :zip
          Utils.oo_spawn("/usr/bin/unzip -d #{target} #{source}",
                         expected_exitstatus: 0)
        when :tgz
          Utils.oo_spawn("/bin/tar -C #{target} -zxpf #{source}",
                         expected_exitstatus: 0)

        when :tar
          Utils.oo_spawn("/bin/tar -C #{target} -xpf #{source}",
                         expected_exitstatus: 0)

        else
          raise "Packaging method #{method} not yet supported."
      end

      files = Dir.glob(PathUtils.join(target, '*'))
      if 1 == files.size
        # A directory of one file is not legal move everyone up a level (github zip's are this way)
        to_delete = files.first + '.to_delete'
        File.rename(files.first, to_delete)

        entries = Dir.glob(File.join(to_delete, '*'), File::FNM_DOTMATCH).delete_if do |e|
          %w(. ..).include? File.basename(e)
        end

        FileUtils.move(entries, target, verbose: true)
        FileUtils.rm_rf(to_delete)
      end
    end

    def self.valid_cartridge_home(cartridge, path)
      errors = []
      [
          [File, :directory?, %w(metadata)],
          [File, :directory?, %w(bin)],
          [File, :file?, %w(metadata manifest.yml)],
          [File, :executable?, %w(bin control)],
      ].each do |clazz, method, target|
        relative = PathUtils.join(target)
        absolute = PathUtils.join(path, relative)

        unless clazz.method(method).(absolute)
          errors << "#{relative} is not #{method}"
        end
      end

      unless errors.empty?
        raise MalformedCartridgeError.new(
                  "Malformed cartridge (#{cartridge.name}, #{cartridge.version}, #{cartridge.cartridge_version})",
                  errors
              )
      end
    end
  end

  # MalformedCartridgeError will be raised if the cartridge instance is missing
  #   files or they do not have expected settings.
  #
  #  MalformedCartridgeError#message provides minimal information.
  #  MalformedCartridgeError#details or #to_s will provide exact issues.
  #
  class MalformedCartridgeError < RuntimeError
    attr_reader :details

    def initialize(message = nil, details = [])
      super(message)
      @details = details
    end

    def to_s
      super + ":\n#{@details.join(', ')}"
    end
  end
end