module Bosh::AzureCloud
  class VMManager
    attr_accessor :logger

    include Helpers

    def initialize(storage_manager, registry, disk_manager)
      @storage_manager = storage_manager
      @registry = registry
      @disk_manager = disk_manager

      @azure_cloud_service    = Azure::CloudServiceManagement::CloudServiceManagementService.new
      @azure_vm_service       = Azure::VirtualMachineManagementService.new
      @reserved_ip_manager    = Bosh::AzureCloud::ReservedIpManager.new
      @affinity_group_manager = Bosh::AzureCloud::AffinityGroupManager.new

      @logger = Bosh::Clouds::Config.logger
    end

    def create(uuid, stemcell, cloud_opts, network_configurator, resource_pool)
      network_property = network_configurator.network.spec["cloud_properties"]
      
      params = {
          :vm_name             => "bosh-vm-#{uuid}",
          :vm_user             => cloud_opts['ssh_user'],
          :image               => stemcell,
          :location           => cloud_opts['location'],
          :domain_name   =>   network_property["domain_name"],
          :virtual_network_name =>   network_property["virtual_network_name"],
          :ip => network_configurator.network.spec["ip"],
          :subnet_name => network_property["subnet_name"],
          :vm_size => resource_pool['instance_type'],
          :password => cloud_opts['password'],
          :storage_account_name => @storage_manager.get_storage_account_name,
      }

      deploy_script_paramter = { 
          :custom_data =>  get_user_data(params[:vm_name],  network_configurator.network.spec["dns"]),
          :ssh_key => cloud_opts['vm_authorized_keys'],
          :vm_user => params[:vm_user]
                               }
      params[:deploy_script_paramter] = deploy_script_paramter.to_json()

      endpoints = []
      network_configurator.tcp_endpoints.split(",").each{|p|
          endpoints.push({
                    :enableDirectServerReturn=>"False",
                    :endpointName=>"tcp"+p.split(":")[0].strip,
                    :publicPort=>p.split(":")[0].strip,
                    :privatePort=>p.split(":")[1].strip,
                    :protocol=> "tcp"
                   }
                   )
      }
      network_configurator.udp_endpoints.split(",").each{|p|
          endpoints.push({
                    :enableDirectServerReturn=>"False",
                    :endpointName=>"udp"+p.split(":")[0].strip,
                    :publicPort=>p.split(":")[0].strip,
                    :privatePort=>p.split(":")[1].strip,
                    :protocol=> "udp"
            })
      }

      params[:endpoints]=endpoints
      crp_params={}
      params.each_pair do |key,values| crp_params[key]={"value"=>values}  end
    
     
     require 'open3'
     deployt_crp_log  = ""
     exit_status = 0

     `azure config mode arm`
     Open3.popen3("azure","group","deployment","create",cloud_opts['resource_group_name'],
                    "-n",params[:vm_name],"-f",File.join(File.dirname(__FILE__),"bosh_deploy_vm.json"),"-p",crp_params.to_json) {|stdin, stdout, stderr, wait_thr|
         pid = wait_thr.pid # pid of the started process
         exit_status = wait_thr.value 
         deployt_crp_log<<stdout.read
         deployt_crp_log<<stderr.read
     }

      logger.debug("Create VM: #{deployt_crp_log}")
      if  exit_status !=0
        logger.error("Failed to create vm")
        cloud_error("Failed to create vm")
      end
      {:cloud_service_name=>params[:domain_name], :vm_name=>params[:vm_name]}

    end

    def find(instance_id)
      cloud_service_name, vm_name = parse_instance_id(instance_id)
      @azure_vm_service.get_virtual_machine(vm_name, cloud_service_name)
    end

    def delete(instance_id)
      cloud_service_name, vm_name = parse_instance_id(instance_id)
      @azure_vm_service.delete_virtual_machine(vm_name, cloud_service_name)
    end

    def reboot(instance_id)
      cloud_service_name, vm_name = parse_instance_id(instance_id)
      @azure_vm_service.restart_virtual_machine(vm_name, cloud_service_name)
    end

    def start(instance_id)
      cloud_service_name, vm_name = parse_instance_id(instance_id)
      @azure_vm_service.start_virtual_machine(vm_name, cloud_service_name)
    end

    def shutdown(instance_id)
      cloud_service_name, vm_name = parse_instance_id(instance_id)
      @azure_vm_service.shutdown_virtual_machine(vm_name, cloud_service_name)
    end

    def instance_id(wala_lib_path)
      contents = File.open(wala_lib_path + "/SharedConfig.xml", "r"){ |file| file.read }

      service_name = contents.match("^*<Service name=\"(.*)\" guid=\"{[-0-9a-fA-F]+}\"[\\s]*/>")[1]
      vm_name = contents.match("^*<Incarnation number=\"\\d*\" instance=\"(.*)\" guid=\"{[-0-9a-fA-F]+}\"[\\s]*/>")[1]
      
      generate_instance_id(service_name, vm_name)
    end
    
    ##
    # Attach a disk to the Vm
    #
    # @param [String] instance_id Instance id
    # @param [String] disk_name disk name
    # @return [String] volume name. "/dev/sd[c-r]"
    def attach_disk(instance_id, disk_name)
      vm = find(instance_id) || cloud_error('Given instance id does not exist')
      
      cloud_service_name, vm_name = parse_instance_id(instance_id)
      
      options = {
          :import => true,
          :disk_name => disk_name,
          :host_caching => 'ReadOnly',
          :disk_label => 'bosh',
          :lun => get_next_disk_lun(vm)
      }
      @azure_vm_service.add_data_disk(vm_name, cloud_service_name, options)
      
      get_volume_name(instance_id, disk_name)
    end
    
    def detach_disk(instance_id, disk_name)
      vm = find(instance_id) || cloud_error('Given instance id does not exist')
      
      cloud_service_name, vm_name = parse_instance_id(instance_id)
      
      data_disk = vm.data_disks.find { |disk| disk[:name] == disk_name}
      data_disk || cloud_error('Given disk name is not attached to given instance id')
      
      lun = get_disk_lun(data_disk)
      http_delete("services/hostedservices/#{cloud_service_name}/deployments/#{vm.deployment_name}/"\
                             "roles/#{vm_name}/DataDisks/#{lun}")
    end
    
    def get_disks(instance_id)
      vm = find(instance_id) || cloud_error('Given instance id does not exist')
      
      data_disks = []
      vm.data_disks.each do |disk|
        data_disks << disk[:name]
      end
      
      data_disks
    end
    
    private
    
    def get_user_data(vm_name, dns)
      user_data = {registry: {endpoint: @registry.endpoint}}
      user_data[:server] = {name: vm_name}
      user_data[:dns] = {nameserver: dns} if dns

      Base64.strict_encode64(Yajl::Encoder.encode(user_data))
    end
    
    def get_volume_name(instance_id, disk_name)
      vm = find(instance_id) || cloud_error('Given instance id does not exist')
      
      data_disk = vm.data_disks.find { |disk| disk[:name] == disk_name}
      data_disk || cloud_error('Given disk name is not attached to given instance id')
      
      lun = get_disk_lun(data_disk)
      
      "/dev/sd#{('c'.ord + lun).chr}"
    end
    
    def get_disk_lun(data_disk)
      data_disk[:lun] != "" ? data_disk[:lun].to_i : 0
    end
    
    def get_next_disk_lun(vm)
      vm.data_disks.size
    end
  end
end
