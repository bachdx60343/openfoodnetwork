require 'spec_helper'

module Admin
  describe OrderCyclesController, type: :controller do
    include AuthenticationWorkflow

    let!(:distributor_owner) { create_enterprise_user enterprise_limit: 2 }

    before do
      controller.stub spree_current_user: distributor_owner
    end

    describe "#index" do
      describe "when the user manages a coordinator" do
        let!(:coordinator) { create(:distributor_enterprise, owner: distributor_owner) }
        let!(:oc1) { create(:simple_order_cycle, orders_open_at: 70.days.ago, orders_close_at: 60.days.ago ) }
        let!(:oc2) { create(:simple_order_cycle, orders_open_at: 70.days.ago, orders_close_at: 40.days.ago ) }
        let!(:oc3) { create(:simple_order_cycle, orders_open_at: 70.days.ago, orders_close_at: 20.days.ago ) }
        let!(:oc4) { create(:simple_order_cycle, orders_open_at: 70.days.ago, orders_close_at: nil ) }

        context "html" do
          it "doesn't load any data" do
            spree_get :index, format: :html
            expect(assigns(:collection)).to be_empty
          end
        end

        context "json" do
          context "where ransack conditions are specified" do
            it "loads order cycles that closed within the past month, and orders without a close_at date" do
              spree_get :index, format: :json
              expect(assigns(:collection)).to_not include oc1, oc2
              expect(assigns(:collection)).to include oc3, oc4
            end
          end

          context "where q[orders_close_at_gt] is set" do
            let(:q) { { orders_close_at_gt: 45.days.ago } }

            it "loads order cycles that closed after the specified date, and orders without a close_at date" do
              spree_get :index, format: :json, q: q
              expect(assigns(:collection)).to_not include oc1
              expect(assigns(:collection)).to include oc2, oc3, oc4
            end

            context "and other conditions are specified" do
              before { q.merge!(id_not_in: [oc2.id, oc4.id]) }

              it "loads order cycles that meet all conditions" do
                spree_get :index, format: :json, q: q
                expect(assigns(:collection)).to_not include oc1, oc2, oc4
                expect(assigns(:collection)).to include oc3
              end
            end
          end
        end
      end
    end

    describe "new" do
      describe "when the user manages a single distributor enterprise suitable for coordinator" do
        let!(:distributor) { create(:distributor_enterprise, owner: distributor_owner) }

        it "renders the new template" do
          spree_get :new
          expect(response).to render_template :new
        end
      end

      describe "when a user manages multiple enterprises suitable for coordinator" do
        let!(:distributor1) { create(:distributor_enterprise, owner: distributor_owner) }
        let!(:distributor2) { create(:distributor_enterprise, owner: distributor_owner) }
        let!(:distributor3) { create(:distributor_enterprise) }

        it "renders the set_coordinator template" do
          spree_get :new
          expect(response).to render_template :set_coordinator
        end

        describe "and a coordinator_id is submitted as part of the request" do
          describe "when the user manages the enterprise" do
            it "renders the new template" do
              spree_get :new, coordinator_id: distributor1.id
              expect(response).to render_template :new
            end
          end

          describe "when the user does not manage the enterprise" do
            it "renders the set_coordinator template and sets a flash error" do
              spree_get :new, coordinator_id: distributor3.id
              expect(response).to render_template :set_coordinator
              expect(flash[:error]).to eq "You don't have permission to create an order cycle coordinated by that enterprise"
            end
          end
        end
      end
    end

    describe "create" do
      let(:shop) { create(:distributor_enterprise) }

      context "as a manager of a shop" do
        let(:form_mock) { instance_double(OrderCycleForm) }
        let(:params) { { format: :json, order_cycle: {} } }

        before do
          login_as_enterprise_user([shop])
          allow(OrderCycleForm).to receive(:new) { form_mock }
        end

        context "when creation is successful" do
          before { allow(form_mock).to receive(:save) { true } }

          it "returns success: true" do
            spree_post :create, params
            json_response = JSON.parse(response.body)
            expect(json_response['success']).to be true
          end
        end

        context "when an error occurs" do
          before { allow(form_mock).to receive(:save) { false } }

          it "returns an errors hash" do
            spree_post :create, params
            json_response = JSON.parse(response.body)
            expect(json_response['errors']).to be
          end
        end
      end
    end

    describe "update" do
      let(:order_cycle) { create(:simple_order_cycle) }
      let(:coordinator) { order_cycle.coordinator }
      let(:form_mock) { instance_double(OrderCycleForm) }

      before do
        allow(OrderCycleForm).to receive(:new) { form_mock }
      end

      context "as a manager of the coordinator" do
        before { login_as_enterprise_user([coordinator]) }
        let(:params) { { format: :json, id: order_cycle.id, order_cycle: {} } }

        context "when updating succeeds" do
          before { allow(form_mock).to receive(:save) { true } }

          context "when the page is reloading" do
            before { params[:reloading] = '1' }

            it "sets flash message" do
              spree_put :update, params
              flash[:notice].should == 'Your order cycle has been updated.'
            end
          end

          context "when the page is not reloading" do
            it "does not set flash message" do
              spree_put :update, params
              flash[:notice].should be nil
            end
          end
        end

        context "when a validation error occurs" do
          before { allow(form_mock).to receive(:save) { false } }

          it "returns an error message" do
            spree_put :update, params
            json_response = JSON.parse(response.body)
            expect(json_response['errors']).to be
          end
        end
      end
    end

    describe "limiting update scope" do
      let(:order_cycle) { create(:simple_order_cycle) }
      let(:producer) { create(:supplier_enterprise) }
      let(:coordinator) { order_cycle.coordinator }
      let(:hub) { create(:distributor_enterprise) }
      let(:v) { create(:variant) }
      let!(:incoming_exchange) { create(:exchange, order_cycle: order_cycle, sender: producer, receiver: coordinator, incoming: true, variants: [v]) }
      let!(:outgoing_exchange) { create(:exchange, order_cycle: order_cycle, sender: coordinator, receiver: hub, incoming: false, variants: [v]) }

      let(:allowed) { { incoming_exchanges: [], outgoing_exchanges: [] } }
      let(:restricted) { { name: 'some name', orders_open_at: 1.day.from_now, orders_close_at: 1.day.ago } }
      let(:params) { { format: :json, id: order_cycle.id, order_cycle: allowed.merge(restricted) } }
      let(:form_mock) { instance_double(OrderCycleForm, save: true) }

      before { allow(controller).to receive(:spree_current_user) { user } }

      context "as a manager of the coordinator" do
        let(:user) { coordinator.owner }
        let(:expected) { [order_cycle, hash_including(order_cycle: allowed.merge(restricted)), user] }

        it "allows me to update exchange information for exchanges, name and dates" do
          expect(OrderCycleForm).to receive(:new).with(*expected) { form_mock }
          spree_put :update, params
        end
      end

      context "as a producer supplying to an order cycle" do
        let(:user) { producer.owner }
        let(:expected) { [order_cycle, hash_including(order_cycle: allowed), user] }

        it "allows me to update exchange information for exchanges, but not name or dates" do
          expect(OrderCycleForm).to receive(:new).with(*expected) { form_mock }
          spree_put :update, params
        end
      end
    end

    describe "bulk_update" do
      let(:oc) { create(:simple_order_cycle) }
      let!(:coordinator) { oc.coordinator }

      context "when I manage the coordinator of an order cycle" do
        let(:params) do
          { format: :json, order_cycle_set: { collection_attributes: { '0' => {
            id: oc.id,
            name: "Updated Order Cycle",
            orders_open_at: Date.current - 21.days,
            orders_close_at: Date.current + 21.days,
          } } } }
        end

        before { create(:enterprise_role, user: distributor_owner, enterprise: coordinator) }

        it "updates order cycle properties" do
          spree_put :bulk_update, params
          oc.reload
          expect(oc.name).to eq "Updated Order Cycle"
          expect(oc.orders_open_at.to_date).to eq Date.current - 21.days
          expect(oc.orders_close_at.to_date).to eq Date.current + 21.days
        end

        it "does nothing when no data is supplied" do
          expect do
            spree_put :bulk_update, format: :json
          end.to change(oc, :orders_open_at).by(0)
          json_response = JSON.parse(response.body)
          expect(json_response['errors']).to eq I18n.t('admin.order_cycles.bulk_update.no_data')
        end

        context "when a validation error occurs" do
          before do
            params[:order_cycle_set][:collection_attributes]['0'][:orders_open_at] = Date.current + 25.days
          end

          it "returns an error message" do
            spree_put :bulk_update, params
            json_response = JSON.parse(response.body)
            expect(json_response['errors']).to be_present
          end
        end
      end

      context "when I do not manage the coordinator of an order cycle" do
        # I need to manage a hub in order to access the bulk_update action
        let!(:another_distributor) { create(:distributor_enterprise, users: [distributor_owner]) }

        it "doesn't update order cycle properties" do
          spree_put :bulk_update, format: :json, order_cycle_set: { collection_attributes: { '0' => {
            id: oc.id,
            name: "Updated Order Cycle",
            orders_open_at: Date.current - 21.days,
            orders_close_at: Date.current + 21.days,
          } } }

          oc.reload
          expect(oc.name).to_not eq "Updated Order Cycle"
          expect(oc.orders_open_at.to_date).to_not eq Date.current - 21.days
          expect(oc.orders_close_at.to_date).to_not eq Date.current + 21.days
        end
      end
    end


    describe "notifying producers" do
      let(:user) { create_enterprise_user }
      let(:admin_user) do
        user = create(:user)
        user.spree_roles << Spree::Role.find_or_create_by_name!('admin')
        user
      end
      let(:order_cycle) { create(:simple_order_cycle) }

      before do
        controller.stub spree_current_user: admin_user
      end

      it "enqueues a job" do
        expect do
          spree_post :notify_producers, {id: order_cycle.id}
        end.to enqueue_job OrderCycleNotificationJob
      end

      it "redirects back to the order cycles path with a success message" do
        spree_post :notify_producers, {id: order_cycle.id}
        expect(response).to redirect_to admin_order_cycles_path
        flash[:notice].should == 'Emails to be sent to producers have been queued for sending.'
      end
    end


    describe "destroy" do
      let(:distributor) { create(:distributor_enterprise, owner: distributor_owner) }
      let(:oc) { create(:simple_order_cycle, coordinator: distributor) }

      describe "when an order cycle is deleteable" do
        it "allows the order_cycle to be destroyed" do
          spree_get :destroy, id: oc.id
          expect(OrderCycle.find_by_id(oc.id)).to be nil
        end
      end

      describe "when an order cycle becomes non-deletable due to the presence of an order" do
        let!(:order) { create(:order, order_cycle: oc) }

        it "displays an error message when we attempt to delete it" do
          spree_get :destroy, id: oc.id
          expect(response).to redirect_to admin_order_cycles_path
          expect(flash[:error]).to eq I18n.t('admin.order_cycles.destroy_errors.orders_present')
        end
      end

      describe "when an order cycle becomes non-deletable because it is linked to a schedule" do
        let!(:schedule) { create(:schedule, order_cycles: [oc]) }

        it "displays an error message when we attempt to delete it" do
          spree_get :destroy, id: oc.id
          expect(response).to redirect_to admin_order_cycles_path
          expect(flash[:error]).to eq I18n.t('admin.order_cycles.destroy_errors.schedule_present')
        end
      end
    end

  end
end
