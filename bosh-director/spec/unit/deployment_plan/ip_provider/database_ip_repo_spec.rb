require 'spec_helper'

module Bosh::Director::DeploymentPlan
  describe DatabaseIpRepo do
    let(:ip_repo) { DatabaseIpRepo.new(logger) }
    let(:instance) { double(:instance, model: Bosh::Director::Models::Instance.make) }
    let(:network_spec) {
      {
        'name' => 'my-manual-network',
        'subnets' => [
          {
            'range' => '192.168.1.0/29',
            'gateway' => '192.168.1.1',
            'dns' => ['192.168.1.1', '192.168.1.2'],
            'static' => [],
            'reserved' => [],
            'cloud_properties' => {},
            'availability_zone' => 'az-1',
          }
        ]
      }
    }
    let(:global_network_resolver) { instance_double(GlobalNetworkResolver, reserved_legacy_ranges: Set.new) }
    let(:availability_zones) { [BD::DeploymentPlan::AvailabilityZone.new('az-1', {})] }
    let(:network) do
      ManualNetwork.parse(
        network_spec,
        availability_zones,
        global_network_resolver,
        logger
      )
    end
    let(:subnet) do
      ManualNetworkSubnet.parse(
        network.name,
        network_spec['subnets'].first,
        availability_zones,
        []
      )
    end

    before do
      Bosh::Director::Config.current_job = Bosh::Director::Jobs::BaseJob.new
      Bosh::Director::Config.current_job.task_id = 'fake-task-id'
    end

    def cidr_ip(ip)
      NetAddr::CIDR.create(ip).to_i
    end

    context :add do
      def dynamic_reservation_with_ip(ip)
        reservation = BD::DesiredNetworkReservation.new_dynamic(instance, network_without_static_pool)
        reservation.resolve_ip(ip)
        reservation.mark_reserved
        ip_repo.add(reservation)

        reservation
      end

      let(:network_without_static_pool) do
        network_spec['subnets'].first['static'] = []
        ManualNetwork.parse(network_spec, availability_zones, global_network_resolver, logger)
      end

      context 'when reservation changes type' do
        context 'from Static to Dynamic' do
          it 'updates type of reservation' do
            network_spec['subnets'].first['static'] = ['192.168.1.5']
            static_reservation = BD::DesiredNetworkReservation.new_static(instance, network, '192.168.1.5')
            ip_repo.add(static_reservation)

            expect(Bosh::Director::Models::IpAddress.count).to eq(1)
            original_address = Bosh::Director::Models::IpAddress.first
            expect(original_address.static).to eq(true)

            dynamic_reservation = dynamic_reservation_with_ip('192.168.1.5')
            ip_repo.add(dynamic_reservation)

            expect(Bosh::Director::Models::IpAddress.count).to eq(1)
            new_address = Bosh::Director::Models::IpAddress.first
            expect(new_address.static).to eq(false)
            expect(new_address.address).to eq(original_address.address)
          end
        end

        context 'from Dynamic to Static' do
          it 'update type of reservation' do
            dynamic_reservation = dynamic_reservation_with_ip('192.168.1.5')
            ip_repo.add(dynamic_reservation)

            expect(Bosh::Director::Models::IpAddress.count).to eq(1)
            original_address = Bosh::Director::Models::IpAddress.first
            expect(original_address.static).to eq(false)

            network_spec['subnets'].first['static'] = ['192.168.1.5']
            static_reservation = BD::DesiredNetworkReservation.new_static(instance, network, '192.168.1.5')
            ip_repo.add(static_reservation)

            expect(Bosh::Director::Models::IpAddress.count).to eq(1)
            new_address = Bosh::Director::Models::IpAddress.first
            expect(new_address.static).to eq(true)
            expect(new_address.address).to eq(original_address.address)
          end
        end

        context 'from Existing to Static' do
          it 'updates type of reservation' do
            dynamic_reservation = dynamic_reservation_with_ip('192.168.1.5')
            ip_repo.add(dynamic_reservation)

            expect(Bosh::Director::Models::IpAddress.count).to eq(1)
            original_address = Bosh::Director::Models::IpAddress.first
            expect(original_address.static).to eq(false)

            network_spec['subnets'].first['static'] = ['192.168.1.5']
            existing_reservation = BD::ExistingNetworkReservation.new(instance, network, '192.168.1.5')
            ip_repo.add(existing_reservation)

            expect(Bosh::Director::Models::IpAddress.count).to eq(1)
            new_address = Bosh::Director::Models::IpAddress.first
            expect(new_address.static).to eq(true)
            expect(new_address.address).to eq(original_address.address)
          end
        end
      end

      context 'when IP is released by another deployment' do
        it 'retries to reserve it' do
          allow_any_instance_of(Bosh::Director::Models::IpAddress).to receive(:save) do
            allow_any_instance_of(Bosh::Director::Models::IpAddress).to receive(:save).and_call_original

            raise Sequel::ValidationFailed.new('address and network_name unique')
          end

          network_spec['subnets'].first['static'] = ['192.168.1.5']
          reservation = BD::DesiredNetworkReservation.new_static(instance, network, '192.168.1.5')
          ip_repo.add(reservation)

          saved_address = Bosh::Director::Models::IpAddress.order(:address).last
          expect(saved_address.address).to eq(cidr_ip('192.168.1.5'))
          expect(saved_address.network_name).to eq('my-manual-network')
          expect(saved_address.task_id).to eq('fake-task-id')
          expect(saved_address.created_at).to_not be_nil
        end
      end

      context 'when reserving an IP with any previous reservation' do
        it 'should fail if it reserved by a different instance' do
          network_spec['subnets'].first['static'] = ['192.168.1.5']

          other_instance = double(:instance, model: Bosh::Director::Models::Instance.make, availability_zone: BD::DeploymentPlan::AvailabilityZone.new('az-2', {}))
          original_static_network_reservation = BD::DesiredNetworkReservation.new_static(instance, network, '192.168.1.5')
          new_static_network_reservation = BD::DesiredNetworkReservation.new_static(other_instance, network, '192.168.1.5')

          ip_repo.add(original_static_network_reservation)

          expect {
            ip_repo.add(new_static_network_reservation)
          }.to raise_error BD::NetworkReservationAlreadyInUse
        end

        it 'should succeed if it is reserved by the same instance' do
          network_spec['subnets'].first['static'] = ['192.168.1.5']

          static_network_reservation = BD::DesiredNetworkReservation.new_static(instance, network, '192.168.1.5')

          ip_repo.add(static_network_reservation)

          expect {
            ip_repo.add(static_network_reservation)
          }.not_to raise_error
        end
      end
    end

    describe :allocate_dynamic_ip do
      let(:reservation) { BD::DesiredNetworkReservation.new_dynamic(instance, network) }

      context 'when there are no IPs reserved for that network' do
        it 'returns the first in the range' do
          ip_address = ip_repo.allocate_dynamic_ip(reservation, subnet)

          expected_ip_address = cidr_ip('192.168.1.2')
          expect(ip_address).to eq(expected_ip_address)
        end
      end

      it 'reserves IP as dynamic' do
        ip_repo.allocate_dynamic_ip(reservation, subnet)

        saved_address = Bosh::Director::Models::IpAddress.first
        expect(saved_address.static).to eq(false)
      end

      context 'when reserving more than one ip' do
        it 'should reserve the next available address' do
          first = ip_repo.allocate_dynamic_ip(reservation, subnet)
          second = ip_repo.allocate_dynamic_ip(reservation, subnet)
          expect(first).to eq(cidr_ip('192.168.1.2'))
          expect(second).to eq(cidr_ip('192.168.1.3'))
        end
      end

      context 'when there are restricted ips' do
        it 'does not reserve them' do
          network_spec['subnets'].first['reserved'] = ['192.168.1.2', '192.168.1.4']

          expect(ip_repo.allocate_dynamic_ip(reservation, subnet)).to eq(cidr_ip('192.168.1.3'))
          expect(ip_repo.allocate_dynamic_ip(reservation, subnet)).to eq(cidr_ip('192.168.1.5'))
        end
      end

      context 'when there are static and restricted ips' do
        it 'does not reserve them' do
          network_spec['subnets'].first['reserved'] = ['192.168.1.2']
          network_spec['subnets'].first['static'] = ['192.168.1.4']

          expect(ip_repo.allocate_dynamic_ip(reservation, subnet)).to eq(cidr_ip('192.168.1.3'))
          expect(ip_repo.allocate_dynamic_ip(reservation, subnet)).to eq(cidr_ip('192.168.1.5'))
        end
      end

      context 'when there are available IPs between reserved IPs' do
        it 'returns first non-reserved IP' do
          network_spec['subnets'].first['static'] = ['192.168.1.2', '192.168.1.4']

          reservation_1 = BD::DesiredNetworkReservation.new_static(instance, network, '192.168.1.2')
          reservation_2 = BD::DesiredNetworkReservation.new_static(instance, network, '192.168.1.4')

          ip_repo.add(reservation_1)
          ip_repo.add(reservation_2)

          reservation_3 = BD::DesiredNetworkReservation.new_dynamic(instance, network)
          ip_address = ip_repo.allocate_dynamic_ip(reservation_3, subnet)

          expect(ip_address).to eq(cidr_ip('192.168.1.3'))
        end
      end

      context 'when all IPs in the range are taken' do
        it 'returns nil' do
          network_spec['subnets'].first['range'] = '192.168.1.0/30'

          ip_repo.allocate_dynamic_ip(reservation, subnet)

          expect(ip_repo.allocate_dynamic_ip(reservation, subnet)).to be_nil
        end
      end

      context 'when reserving IP fails' do
        def fail_saving_ips(ips, fail_error)
          original_saves = {}
          ips.each do |ip|
            ip_address = Bosh::Director::Models::IpAddress.new(
              address: ip,
              network_name: 'my-manual-network',
              instance: instance.model,
              task_id: Bosh::Director::Config.current_job.task_id
            )
            original_save = ip_address.method(:save)
            original_saves[ip] = original_save
          end

          allow_any_instance_of(Bosh::Director::Models::IpAddress).to receive(:save) do |model|
            if ips.include?(model.address)
              original_save = original_saves[model.address]
              original_save.call
              raise fail_error
            end
            model
          end
        end

        shared_examples :retries_on_race_condition do
          context 'when allocating some IPs fails' do
            before do
              network_spec['subnets'].first['range'] = '192.168.1.0/29'

              fail_saving_ips([
                  cidr_ip('192.168.1.2'),
                  cidr_ip('192.168.1.3'),
                  cidr_ip('192.168.1.4'),
                ],
                fail_error
              )
            end

            it 'retries until it succeeds' do
              expect(ip_repo.allocate_dynamic_ip(reservation, subnet)).to eq(cidr_ip('192.168.1.5'))
            end
          end

          context 'when allocating any IP fails' do
            before do
              network_spec['subnets'].first['range'] = '192.168.1.0/29'
              network_spec['subnets'].first['reserved'] = ['192.168.1.5', '192.168.1.6']

              fail_saving_ips([
                  cidr_ip('192.168.1.2'),
                  cidr_ip('192.168.1.3'),
                  cidr_ip('192.168.1.4')
                ],
                fail_error
              )
            end

            it 'retries until there are no more IPs available' do
              expect(ip_repo.allocate_dynamic_ip(reservation, subnet)).to be_nil
            end
          end
        end

        context 'when sequel validation errors' do
          let(:fail_error) { Sequel::ValidationFailed.new('address and network are not unique') }

          it_behaves_like :retries_on_race_condition
        end

        context 'when postgres unique errors' do
          let(:fail_error) { Sequel::DatabaseError.new('duplicate key value violates unique constraint') }

          it_behaves_like :retries_on_race_condition
        end

        context 'when mysql unique errors' do
          let(:fail_error) { Sequel::DatabaseError.new('Duplicate entry') }

          it_behaves_like :retries_on_race_condition
        end
      end
    end

  end
end