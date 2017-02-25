# -*- mode: ruby -*-
# vi: set ft=ruby :

require 'fileutils'
require 'net/http'
require 'open-uri'
require 'json'
require 'date'
require 'pathname'
require 'yaml'

if File.file?('config.yaml')
  clusters =  YAML.load_file(File.join(File.dirname(__FILE__), 'config.yaml'))
else
  raise "Configuration file 'config.yaml' does not exist."
end

class Module
  def redefine_const(name, value)
    __send__(:remove_const, name) if const_defined?(name)
    const_set(name, value)
  end
end

module OS
  def OS.windows?
    (/cygwin|mswin|mingw|bccwin|wince|emx/ =~ RUBY_PLATFORM) != nil
  end

  def OS.mac?
   (/darwin/ =~ RUBY_PLATFORM) != nil
  end

  def OS.unix?
    !OS.windows?
  end

  def OS.linux?
    OS.unix? and not OS.mac?
  end
end

required_plugins = %w(vagrant-triggers)

if OS.windows?
  required_plugins.push('vagrant-winnfsd')
end

required_plugins.push('vagrant-timezone')

required_plugins.each do |plugin|
  need_restart = false
  unless Vagrant.has_plugin? plugin
    system "vagrant plugin install #{plugin}"
    need_restart = true
  end
  exec "vagrant #{ARGV.join(' ')}" if need_restart
end


CERTS_MASTER_SCRIPT = File.join(File.dirname(__FILE__), "tls/make-certs-master.sh")
CERTS_MASTER_CONF = File.join(File.dirname(__FILE__), "tls/openssl-master.cnf.tmpl")
CERTS_NODE_SCRIPT = File.join(File.dirname(__FILE__), "tls/make-certs-node.sh")
CERTS_NODE_CONF = File.join(File.dirname(__FILE__), "tls/openssl-node.cnf.tmpl")

DNS_UPSTREAM_SERVERS = ENV['DNS_UPSTREAM_SERVERS'] || "8.8.8.8:53,8.8.4.4:53"

MANIFESTS_DIR = Pathname.getwd().join("manifests")

USE_DOCKERCFG = ENV['USE_DOCKERCFG'] || false
DOCKERCFG = File.expand_path(ENV['DOCKERCFG'] || "~/.dockercfg")

DOCKER_OPTIONS = ENV['DOCKER_OPTIONS'] || ''


BOX_TIMEOUT_COUNT = ENV['BOX_TIMEOUT_COUNT'] || 50

# check either 'http_proxy' or 'HTTP_PROXY' environment variable
enable_proxy = !(ENV['HTTP_PROXY'] || ENV['http_proxy'] || '').empty?
if enable_proxy
  required_plugins.push('vagrant-proxyconf')
end

if enable_proxy
  HTTP_PROXY = ENV['HTTP_PROXY'] || ENV['http_proxy']
  HTTPS_PROXY = ENV['HTTPS_PROXY'] || ENV['https_proxy']
  NO_PROXY = ENV['NO_PROXY'] || ENV['no_proxy'] || "localhost"
end

SERIAL_LOGGING = (ENV['SERIAL_LOGGING'].to_s.downcase == 'true')
GUI = (ENV['GUI'].to_s.downcase == 'true')

CHANNEL = ENV['CHANNEL'] || 'alpha'
#if CHANNEL != 'alpha'
#  puts "============================================================================="
#  puts "As this is a fastly evolving technology CoreOS' alpha channel is the only one"
#  puts "expected to behave reliably. While one can invoke the beta or stable channels"
#  puts "please be aware that your mileage may vary a whole lot."
#  puts "So, before submitting a bug, in this project, or upstreams (either kubernetes"
#  puts "or CoreOS) please make sure it (also) happens in the (default) alpha channel."
#  puts "============================================================================="
#end

COREOS_VERSION = ENV['COREOS_VERSION'] || 'latest'
upstream = "http://#{CHANNEL}.release.core-os.net/amd64-usr/#{COREOS_VERSION}"
if COREOS_VERSION == "latest"
  upstream = "http://#{CHANNEL}.release.core-os.net/amd64-usr/current"
  url = "#{upstream}/version.txt"
  Object.redefine_const(:COREOS_VERSION,
    open(url).read().scan(/COREOS_VERSION=.*/)[0].gsub('COREOS_VERSION=', ''))
end

# Read YAML file with mountpoint details
MOUNT_POINTS = YAML::load_file('synced_folders.yaml')


# Vagrantfile API/syntax version. Don't touch unless you know what you're doing!
VAGRANTFILE_API_VERSION = "2"
Vagrant.require_version ">= 1.8.6"

REMOVE_VAGRANTFILE_USER_DATA_BEFORE_HALT = (ENV['REMOVE_VAGRANTFILE_USER_DATA_BEFORE_HALT'].to_s.downcase == 'true')
# if this is set true, remember to use --provision when executing vagrant up / reload

#REGION Configure
Vagrant.configure(VAGRANTFILE_API_VERSION) do |config|

  #REGION Cluster
  clusters.each do |clusters|     

    master_yaml = File.join(File.dirname(__FILE__), clusters['master_yaml'])
    node_yaml = File.join(File.dirname(__FILE__), clusters['node_yaml'])   
    cluster_name = clusters['cluster_name']

    nodes = clusters['nodes']

    base_ip_addr = clusters['base_ip_addr']   

    dns_domain= clusters['dns_domain']

    use_kube_ui = clusters['use_kube_ui']
    kubernetes_version = clusters['kubernetes_version']

    # always use host timezone in VMs
    config.timezone.value = :host

    # always use Vagrants' insecure key
    config.ssh.insert_key = false
    config.ssh.forward_agent = true   

   
    config.vm.provider :virtualbox do |v|
      # On VirtualBox, we don't have guest additions or a functional vboxsf
      # in CoreOS, so tell Vagrant that so it can be smarter.
      v.check_guest_additions = false
      v.functional_vboxsf     = false
    end
    config.vm.provider :parallels do |p|
      p.update_guest_tools = false
      p.check_guest_tools = false
    end

    # plugin conflict
    if Vagrant.has_plugin?("vagrant-vbguest") then
      config.vbguest.auto_update = false
    end

    # setup VM proxy to system proxy environment
    if Vagrant.has_plugin?("vagrant-proxyconf") && enable_proxy
      config.proxy.http = HTTP_PROXY
      config.proxy.https = HTTPS_PROXY
      # most http tools, like wget and curl do not undestand IP range
      # thus adding each node one by one to no_proxy
      no_proxies = NO_PROXY.split(",")
      (1..(nodes.to_i + 1)).each do |i|
        vm_ip_addr = "#{base_ip_addr}.#{i+100}"
        Object.redefine_const(:NO_PROXY,
          "#{NO_PROXY},#{vm_ip_addr}") unless no_proxies.include?(vm_ip_addr)
      end
      config.proxy.no_proxy = NO_PROXY
      # proxyconf plugin use wrong approach to set Docker proxy for CoreOS
      # force proxyconf to skip Docker proxy setup
      config.proxy.enabled = { docker: false }
    end

    #REGION Nodes
    (1..(nodes.to_i + 2)).each do |i|     

            #region Deploy Router
            if i == 1 # First Node is Router, every cluster gets one
              hostname = "#{cluster_name}-router"
              memory = clusters["router_mem"]
              cpus = clusters["router_cpus"]

              config.vm.define vmName = hostname do |rHost|

                  rHost.vm.hostname = vmName
                
                  # Synced folders is not needed (and doesn't work) with the vyos box used...
                  rHost.vm.synced_folder ".", "/vagrant", disabled: true
              
                  rHost.vm.box = "higebu/vyos"
                  if clusters["router_external_ip"]
                    rHost.vm.network :public_network, ip: clusters["router_external_ip"]
                  else
                    rHost.vm.network :public_network, type: "dhcp"        
                  end
                  rHost.vm.network :private_network, virtualbox__intnet: "network-#{cluster_name}"

                  rHost.vm.provision "shell",                
                  inline: <<-EOF #!/bin/vbash

                            source /opt/vyatta/etc/functions/script-template

                            # Add desctiption for NAT and External Interface
                            set interfaces ethernet eth0 description 'NAT'
                            set interfaces ethernet eth1 description 'External'

                            #Configure vLans for private network
                            set interfaces ethernet eth2 address #{base_ip_addr}.1/24
                            set interfaces ethernet eth2 description 'Untagged'

                            #Enable DNS forwarding for private network
                            #set service dns forwarding system
                            #set service dns forwarding cache-size 0

                            # Home
                            set system gateway-address #{clusters['router_external_gateway']}
                            set system name-server #{clusters['router_external_dns']}

                            set service dns forwarding listen-on eth2

                            #Configure NAT
                            set nat source rule 100 outbound-interface eth1
                            set nat source rule 100 translation address masquerade

                            set protocols static route 0.0.0.0/0 next-hop #{clusters['router_external_gateway']} distance '1'
                            set protocols static route #{base_ip_addr}.0/16 next-hop 0.0.0.0


                            commit
                            save
                        EOF
                end
            
          
        else #ENDREGION Deploy Router
         #REGION Deploy Kubernetes
                if i == 2
                  hostname = "#{cluster_name}-master"  
                  etcd_seed_cluster = "#{hostname}=http://#{base_ip_addr}.#{i+100}:2380"            
                  cfg = master_yaml
                  memory = clusters["master_mem"]
                  cpus = clusters["master_cpus"]
                  master_ip =  "#{base_ip_addr}.#{i+100}"
                else
                  hostname = "#{cluster_name}-node-%02d" % (i - 2)
                  cfg =  node_yaml
                  memory = clusters["node_mem"]
                  cpus = clusters["node_cpus"]
                  master_ip =  "#{base_ip_addr}.#{i+100}"
                end              

                config.vm.define vmName = hostname do |kHost|
                        kHost.vm.hostname = vmName

                        kHost.vm.box = "coreos-#{CHANNEL}"
                        kHost.vm.box_version = "= #{COREOS_VERSION}"
                        kHost.vm.box_url = "#{upstream}/coreos_production_vagrant.json"

                        ["vmware_fusion", "vmware_workstation"].each do |vmware|
                          kHost.vm.provider vmware do |v, override|
                            override.vm.box_url = "#{upstream}/coreos_production_vagrant_vmware_fusion.json"
                          end
                        end

                        kHost.vm.provider :parallels do |vb, override|
                          override.vm.box = "AntonioMeireles/coreos-#{CHANNEL}"
                          override.vm.box_url = "https://vagrantcloud.com/AntonioMeireles/coreos-#{CHANNEL}"
                        end
                      
                        # suspend / resume is hard to be properly supported because we have no way
                        # to assure the fully deterministic behavior of whatever is inside the VMs
                        # when faced with XXL clock gaps... so we just disable this functionality.
                        kHost.trigger.reject [:suspend, :resume] do
                          info "'vagrant suspend' and 'vagrant resume' are disabled."
                          info "- please do use 'vagrant halt' and 'vagrant up' instead."
                        end

                        config.trigger.instead_of :reload do
                          exec "vagrant halt && vagrant up"
                          exit
                        end

                        # vagrant-triggers has no concept of global triggers so to avoid having
                        # then to run as many times as the total number of VMs we only call them
                        # in the master (re: emyl/vagrant-triggers#13)...
                        if vmName == "#{cluster_name}-master" 
                          kHost.trigger.before [:up, :provision] do
                            info "#{Time.now}: setting up Kubernetes master..."
                            info "Setting Kubernetes version #{kubernetes_version}"

                            # create setup file
                            setupFile = "#{__dir__}/temp/#{cluster_name}-setup"
                            # find and replace kubernetes version and master IP in setup file
                            setupData = File.read("setup.tmpl")
                            setupData = setupData.gsub("__KUBERNETES_VERSION__", kubernetes_version);
                            setupData = setupData.gsub("__MASTER_IP__", master_ip);
                            if enable_proxy
                              # remove __PROXY_LINE__ flag and set __NO_PROXY__
                              setupData = setupData.gsub("__PROXY_LINE__", "");
                              setupData = setupData.gsub("__NO_PROXY__", NO_PROXY);
                            else
                              # remove lines that start with __PROXY_LINE__
                              setupData = setupData.gsub(/^\s*__PROXY_LINE__.*$\n/, "");
                            end
                            # write new setup data to setup file
                            File.open(setupFile, "wb") do |f|
                              f.write(setupData)
                            end

                            # give setup file executable permissions
                            system "chmod +x temp/#{cluster_name}-setup"

                            # create dns-controller.yaml file
                            dnsFile = "#{__dir__}/temp/#{cluster_name}-dns-controller.yaml"
                            dnsData = File.read("#{__dir__}/plugins/dns/dns-controller.yaml.tmpl")
                            dnsData = dnsData.gsub("__MASTER_IP__", master_ip);
                            dnsData = dnsData.gsub("__DNS_DOMAIN__", dns_domain);
                            dnsData = dnsData.gsub("__DNS_UPSTREAM_SERVERS__", DNS_UPSTREAM_SERVERS);
                            # write new setup data to setup file
                            File.open(dnsFile, "wb") do |f|
                              f.write(dnsData)
                            end
                          end

                          kHost.trigger.after [:up, :resume] do
                            unless OS.windows?
                              info "Sanitizing stuff..."
                              system "ssh-add ~/.vagrant.d/insecure_private_key"
                              system "rm -rf ~/.fleetctl/known_hosts"
                            end
                          end

                          kHost.trigger.after [:up] do
                            info "Waiting for Kubernetes master to become ready..."
                            j, uri, res = 0, URI("http://#{master_ip}:8080"), nil
                            loop do
                              j += 1
                              begin
                                res = Net::HTTP.get_response(uri)
                              rescue
                                sleep 10
                              end
                              break if res.is_a? Net::HTTPSuccess or j >= BOX_TIMEOUT_COUNT
                            end
                            if res.is_a? Net::HTTPSuccess
                              info "#{Time.now}: successfully deployed #{vmName}"
                            else
                              info "#{Time.now}: failed to deploy #{vmName} within timeout count of #{BOX_TIMEOUT_COUNT}"
                            end

                            info "Installing kubectl for the Kubernetes version we just bootstrapped..."
                            if OS.windows?
                              run_remote "sudo -u core /bin/sh /home/core/kubectlsetup install"
                            else
                              system "./temp/#{cluster_name}-setup install"
                            end

                            # set cluster
                            if OS.windows?
                              run_remote "/opt/bin/kubectl config set-cluster default-cluster --server=https://#{master_ip} --certificate-authority=/vagrant/artifacts/#{clusters['cluster_name']}/tls/ca.pem"
                              run_remote "/opt/bin/kubectl config set-credentials default-admin --certificate-authority=/vagrant/artifacts/#{clusters['cluster_name']}/tls/ca.pem --client-key=/vagrant/artifacts/#{clusters['cluster_name']}/tls/admin-key.pem --client-certificate=/vagrant/artifacts/#{clusters['cluster_name']}/tls/admin.pem"
                              run_remote "/opt/bin/kubectl config set-context local --cluster=default-cluster --user=default-admin"
                              run_remote "/opt/bin/kubectl config use-context local"
                            else
                              system "kubectl config set-cluster default-cluster --server=https://#{master_ip} --certificate-authority=/vagrant/artifacts/#{clusters['cluster_name']}/tls/ca.pem"
                              system "kubectl config set-credentials default-admin --certificate-authority=/vagrant/artifacts/#{clusters['cluster_name']}/tls/ca.pem --client-key=/vagrant/artifacts/#{clusters['cluster_name']}/tls/admin-key.pem --client-certificate=/vagrant/artifacts/#{clusters['cluster_name']}/tls/admin.pem"
                              system "kubectl config set-context local --cluster=default-cluster --user=default-admin"
                              system "kubectl config use-context local"
                            end

                            info "Configuring Kubernetes DNS..."
                            res, uri.path = nil, '/api/v1/namespaces/kube-system/replicationcontrollers/kube-dns'
                            begin
                              res = Net::HTTP.get_response(uri)
                            rescue
                            end
                            if not res.is_a? Net::HTTPSuccess
                              if OS.windows?
                                run_remote "/opt/bin/kubectl create -f /home/core/dns-controller.yaml"
                              else
                                system "kubectl create -f temp/#{cluster_name}-dns-controller.yaml"
                              end
                            end

                            res, uri.path = nil, '/api/v1/namespaces/kube-system/services/kube-dns'
                            begin
                              res = Net::HTTP.get_response(uri)
                            rescue
                            end
                            if not res.is_a? Net::HTTPSuccess
                              if OS.windows?
                                run_remote "/opt/bin/kubectl create -f /home/core/dns-service.yaml"
                              else
                                system "kubectl create -f plugins/dns/dns-service.yaml"
                              end
                            end

                            if use_kube_ui
                              info "Configuring Kubernetes dashboard..."

                              res, uri.path = nil, '/api/v1/namespaces/kube-system/replicationcontrollers/kubernetes-dashboard'
                              begin
                                res = Net::HTTP.get_response(uri)
                              rescue
                              end
                              if not res.is_a? Net::HTTPSuccess
                                if OS.windows?
                                  run_remote "/opt/bin/kubectl create -f /home/core/dashboard-controller.yaml"
                                else
                                  system "kubectl create -f plugins/dashboard/dashboard-controller.yaml"
                                end
                              end

                              res, uri.path = nil, '/api/v1/namespaces/kube-system/services/kubernetes-dashboard'
                              begin
                                res = Net::HTTP.get_response(uri)
                              rescue
                              end
                              if not res.is_a? Net::HTTPSuccess
                                if OS.windows?
                                  run_remote "/opt/bin/kubectl create -f /home/core/dashboard-service.yaml"
                                else
                                  system "kubectl create -f plugins/dashboard/dashboard-service.yaml"
                                end
                              end

                              info "Kubernetes dashboard will be available at http://#{master_ip}:8080/ui"
                            end

                          end

                          # copy setup files to master vm if host is windows
                          if OS.windows?
                            kHost.vm.provision :file, :source => File.join(File.dirname(__FILE__), "temp/#{cluster_name}-setup"), :destination => "/home/core/kubectlsetup"
                            kHost.vm.provision :file, :source => File.join(File.dirname(__FILE__), "temp/#{cluster_name}-dns-controller.yaml"), :destination => "/home/core/dns-controller.yaml"
                            kHost.vm.provision :file, :source => File.join(File.dirname(__FILE__), "plugins/dns/dns-service.yaml"), :destination => "/home/core/dns-service.yaml"

                            if use_kube_ui
                              kHost.vm.provision :file, :source => File.join(File.dirname(__FILE__), "plugins/dashboard/dashboard-controller.yaml"), :destination => "/home/core/dashboard-controller.yaml"
                              kHost.vm.provision :file, :source => File.join(File.dirname(__FILE__), "plugins/dashboard/dashboard-service.yaml"), :destination => "/home/core/dashboard-service.yaml"
                            end
                          end

                          # clean temp directory after master is destroyed
                          kHost.trigger.after [:destroy] do
                            FileUtils.rm_rf(Dir.glob("#{__dir__}/temp/*"))
                            FileUtils.rm_rf(Dir.glob("#{__dir__}/vagrant/artifacts/#{cluster_name}/tls/*"))
                          end
                        end

                        if vmName == "#{cluster_name}-node-%02d" % (i - 1)
                          kHost.trigger.before [:up, :provision] do
                            info "#{Time.now}: setting up node..."
                          end

                          kHost.trigger.after [:up] do
                            info "Waiting for Kubernetes minion [node-%02d" % (i - 1) + "] to become ready..."
                            j, uri, hasResponse = 0, URI("http://#{base_ip_addr}.#{i+100}:10250"), false
                            loop do
                              j += 1
                              begin
                                res = Net::HTTP.get_response(uri)
                                hasResponse = true
                              rescue Net::HTTPBadResponse
                                hasResponse = true
                              rescue
                                sleep 10
                              end
                              break if hasResponse or j >= BOX_TIMEOUT_COUNT
                            end
                            if hasResponse
                              info "#{Time.now}: successfully deployed #{vmName}"
                            else
                              info "#{Time.now}: failed to deploy #{vmName} within timeout count of #{BOX_TIMEOUT_COUNT}"
                            end
                          end
                        end

                        kHost.trigger.before [:halt, :reload] do
                          if REMOVE_VAGRANTFILE_USER_DATA_BEFORE_HALT
                            run_remote "sudo rm -f /var/lib/coreos-vagrant/vagrantfile-user-data"
                          end
                        end

                        if SERIAL_LOGGING
                          logdir = File.join(File.dirname(__FILE__), "log")
                          FileUtils.mkdir_p(logdir)

                          serialFile = File.join(logdir, "#{vmName}-serial.txt")
                          FileUtils.touch(serialFile)

                          ["vmware_fusion", "vmware_workstation"].each do |vmware|
                            kHost.vm.provider vmware do |v, override|
                              v.vmx["serial0.present"] = "TRUE"
                              v.vmx["serial0.fileType"] = "file"
                              v.vmx["serial0.fileName"] = serialFile
                              v.vmx["serial0.tryNoRxLoss"] = "FALSE"
                            end
                          end
                          kHost.vm.provider :virtualbox do |vb, override|
                            vb.customize ["modifyvm", :id, "--uart1", "0x3F8", "4"]
                            vb.customize ["modifyvm", :id, "--uartmode1", serialFile]
                          end
                          # supported since vagrant-parallels 1.3.7
                          # https://github.com/Parallels/vagrant-parallels/issues/164
                          kHost.vm.provider :parallels do |v|
                            v.customize("post-import",
                              ["set", :id, "--device-add", "serial", "--output", serialFile])
                            v.customize("pre-boot",
                              ["set", :id, "--device-set", "serial0", "--output", serialFile])
                          end
                        end

                        ["vmware_fusion", "vmware_workstation", "virtualbox"].each do |h|
                          kHost.vm.provider h do |vb|
                            vb.gui = GUI
                          end
                        end
                        ["vmware_fusion", "vmware_workstation"].each do |h|
                          kHost.vm.provider h do |v|
                            v.vmx["memsize"] = memory
                            v.vmx["numvcpus"] = cpus
                          end
                        end
                        ["parallels", "virtualbox"].each do |h|
                          kHost.vm.provider h do |n|
                            n.memory = memory
                            n.cpus = cpus
                          end
                        end
                        
                        # network config
                        kHost.vm.network :private_network, ip: "#{base_ip_addr}.#{i+100}", virtualbox__intnet: "network-#{cluster_name}"
                        kHost.vm.network :private_network, type: "dhcp"

                        # set default gateway to vyos network
                        kHost.vm.provision "shell",
                          inline: "route add default gw #{base_ip_addr}.1"
                        # delete default gw on eth0
                        kHost.vm.provision "shell",
                          inline: "route del default gw 10.0.2.2"

                        # you can override this in synced_folders.yaml
                        kHost.vm.synced_folder ".", "/vagrant", disabled: true

                        begin
                          MOUNT_POINTS.each do |mount|
                            mount_options = ""
                            disabled = false
                            nfs =  true
                            if mount['mount_options']
                              mount_options = mount['mount_options']
                            end
                            if mount['disabled']
                              disabled = mount['disabled']
                            end
                            if mount['nfs']
                              nfs = mount['nfs']
                            end
                            if File.exist?(File.expand_path("#{mount['source']}"))
                              if mount['destination']
                                kHost.vm.synced_folder "#{mount['source']}", "#{mount['destination']}",
                                  id: "#{mount['name']}",
                                  disabled: disabled,
                                  mount_options: ["#{mount_options}"],
                                  nfs: nfs
                              end
                            end
                          end
                        rescue
                        end

                        if USE_DOCKERCFG && File.exist?(DOCKERCFG)
                          kHost.vm.provision :file, run: "always",
                          :source => "#{DOCKERCFG}", :destination => "/home/core/.dockercfg"

                          kHost.vm.provision :shell, run: "always" do |s|
                            s.inline = "cp /home/core/.dockercfg /root/.dockercfg"
                            s.privileged = true
                          end
                        end

                        # Copy TLS stuff
                        if vmName == "#{cluster_name}-master" 
                          kHost.vm.provision :file, :source => "#{CERTS_MASTER_SCRIPT}", :destination => "/tmp/make-certs.sh"
                          kHost.vm.provision :file, :source => "#{CERTS_MASTER_CONF}", :destination => "/tmp/openssl.cnf"
                          kHost.vm.provision :shell, :privileged => true,
                          inline: <<-EOF
                            sed -i"*" "s|__MASTER_IP__|#{master_ip}|g" /tmp/openssl.cnf
                            sed -i"*" "s|__DNS_DOMAIN__|#{dns_domain}|g" /tmp/openssl.cnf
                            sed -i"*" "s|__CLUSTER_NAME__|#{cluster_name}|g" /tmp/make-certs.sh
                          EOF
                        else
                          kHost.vm.provision :file, :source => "#{CERTS_NODE_SCRIPT}", :destination => "/tmp/make-certs.sh"
                          kHost.vm.provision :file, :source => "#{CERTS_NODE_CONF}", :destination => "/tmp/openssl.cnf"
                          kHost.vm.provision :shell, :privileged => true,
                          inline: <<-EOF
                            sed -i"*" "s|__NODE_IP__|#{base_ip_addr}.#{i+100}|g" /tmp/openssl.cnf
                            sed -i"*" "s|__CLUSTER_NAME__|#{cluster_name}|g" /tmp/make-certs.sh
                          EOF
                          kHost.vm.provision :shell, run: "always" do |s|
                            s.inline = "mkdir -p /etc/kubernetes && cp -R /vagrant/tls/node-kubeconfig.yaml /etc/kubernetes/node-kubeconfig.yaml"
                            s.privileged = true
                          end
                        end

                        # Process Kubernetes manifests, depending on node type
                        begin
                          if vmName == "#{cluster_name}-master" 
                            kHost.vm.provision :shell, run: "always" do |s|
                              s.inline = "mkdir -p /etc/kubernetes/manifests && cp -R /vagrant/manifests/master* /etc/kubernetes/manifests"
                              s.privileged = true
                            end
                          else
                            kHost.vm.provision :shell, run: "always" do |s|
                              s.inline = "mkdir -p /etc/kubernetes/manifests && cp -R /vagrant/manifests/node* /etc/kubernetes/manifests/"
                              s.privileged = true
                            end
                          end
                          kHost.vm.provision :shell, :privileged => true,
                          inline: <<-EOF
                            sed -i"*" "s,__RELEASE__,v#{kubernetes_version},g" /etc/kubernetes/manifests/*.yaml
                            sed -i"*" "s|__MASTER_IP__|#{master_ip}|g" /etc/kubernetes/manifests/*.yaml
                            sed -i"*" "s|__DNS_DOMAIN__|#{dns_domain}|g" /etc/kubernetes/manifests/*.yaml
                          EOF
                        end

                        # Process vagrantfile
                        if File.exist?(cfg)
                          kHost.vm.provision :file, :source => "#{cfg}", :destination => "/tmp/vagrantfile-user-data"
                          if enable_proxy
                            kHost.vm.provision :shell, :privileged => true,
                            inline: <<-EOF
                            sed -i"*" "s|__PROXY_LINE__||g" /tmp/vagrantfile-user-data
                            sed -i"*" "s|__HTTP_PROXY__|#{HTTP_PROXY}|g" /tmp/vagrantfile-user-data
                            sed -i"*" "s|__HTTPS_PROXY__|#{HTTPS_PROXY}|g" /tmp/vagrantfile-user-data
                            sed -i"*" "s|__NO_PROXY__|#{NO_PROXY}|g" /tmp/vagrantfile-user-data
                            EOF
                          end
                          kHost.vm.provision :shell, :privileged => true,
                          inline: <<-EOF
                            sed -i"*" "/__PROXY_LINE__/d" /tmp/vagrantfile-user-data
                            sed -i"*" "s,__DOCKER_OPTIONS__,#{DOCKER_OPTIONS},g" /tmp/vagrantfile-user-data
                            sed -i"*" "s,__RELEASE__,v#{kubernetes_version},g" /tmp/vagrantfile-user-data
                            sed -i"*" "s,__CHANNEL__,v#{CHANNEL},g" /tmp/vagrantfile-user-data
                            sed -i"*" "s,__NAME__,#{hostname},g" /tmp/vagrantfile-user-data
                            sed -i"*" "s|__MASTER_IP__|#{master_ip}|g" /tmp/vagrantfile-user-data
                            sed -i"*" "s|__DNS_DOMAIN__|#{dns_domain}|g" /tmp/vagrantfile-user-data
                            sed -i"*" "s|__ETCD_SEED_CLUSTER__|#{etcd_seed_cluster}|g" /tmp/vagrantfile-user-data
                            mv /tmp/vagrantfile-user-data /var/lib/coreos-vagrant/
                          EOF
                        end

                    end
        end #ENDREGION Deploy Kubernetes
    end #ENDREGION Nodes
  end #ENDREGION Cluster
end #ENDREGION Configure
