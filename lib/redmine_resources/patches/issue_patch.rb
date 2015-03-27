module RedmineResources
  module Patches
    module IssuePatch
      def self.included(base)
        base.send :include, InstanceMethods
        base.class_eval do
          has_many :issue_resource, dependent: :destroy
          has_many :resource, through: :issue_resource
          before_save :add_resource_estimation, if: -> do
            estimated_hours_changed? &&
            ResourceSetting.where(project_id: project_id, setting: 1, setting_object_type: 'Tracker')
              .pluck(:setting_object_id).include?(tracker_id)
          end
          after_save :save_resource_estimation, if: -> { @resource_estimation_added }
          after_save :update_parent_estimation
        end
      end

      module InstanceMethods
        def resources_with_departments
          list = IssueResource.includes(resource: :department).where(issue_id: self.id)
          result = {}
          list.each do |element|
            department_name = element.resource.department.name
            result[department_name] = [] unless result[department_name]
            result[department_name] << element
          end
          result
        end

        def add_resource_estimation
          estimation = find_total_estimated_hours_for_resource + estimated_hours
          @altered_resource = find_issue_resource
          mode = nil
          if estimation == 0
            unless @altered_resource.new_record?
              @altered_resource.destroy
              mode = :destroy
            end
          else
            @altered_resource.estimation = estimation
            mode = @altered_resource.new_record? ? :create : :update
            unless new_record?
              @altered_resource.save
            else
              @resource_estimation_added = true
            end
          end
          self.estimated_hours = new_record? ? estimation : find_total_estimated_hours
          return unless @current_journal && mode
          @current_journal.details << @altered_resource.journal_entry(mode, old_value)
        end

        def save_resource_estimation
          @altered_resource.issue_id = id
          @altered_resource.save
        end

        def find_issue_resource
          IssueResource.where(issue_id: parent_id,
            resource_id: determine_resource_type_id
          ).first_or_initialize
        end

        def find_total_estimated_hours
          if Issue.where(parent_id: id).exists?
            Issue.where(parent_id: id).sum(:estimated_hours)
          else
            IssueResource.where(issue_id: id).sum(:estimation)
          end
        end

        def find_total_estimated_hours_for_resource
          Issue.joins(:issue_resource)
            .where('issues.parent_id = ? AND issue_resources.resource_id = ?', id, determine_resource_type_id)
            .sum(:estimated_hours)
        end

        def determine_resource_type_id
          user_id = assigned_to_id || User.current.id
          member = Member.where(user_id: user_id, project_id: project_id).first
          return nil unless member
          member_resource = member.resource
          member_resource ? member_resource.id : nil
        end

        def update_parent_estimation
          parent = Issue.where(id: parent_id).first
          return if !parent || parent.blocked?
          children_estimation_total = Issue.where(
              'issues.tracker_id NOT IN (2,5,6) AND parent_id = ?', parent_id
            ).sum(:estimated_hours)
          children_estimation_total += Issue.where(parent_id: parent_id, tracker_id: 2)
            .sum(:estimated_hours).to_i if parent.tracker_id == 5
          parent.update_column :estimated_hours, children_estimation_total
          parent.update_parent_estimation
        end
      end
    end
  end
end

unless Issue.included_modules.include? RedmineResources::Patches::IssuePatch
  Issue.send :include, RedmineResources::Patches::IssuePatch
end
