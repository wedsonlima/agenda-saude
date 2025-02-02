module Operator
  class AppointmentsController < Base
    before_action :set_ubs

    FILTERS = {
      search: 'search',
      all: 'all',
      waiting: 'waiting',
      checked_in: 'checked_in',
      checked_out: 'checked_out'
    }.freeze

    # rubocop:disable Metrics/AbcSize
    def index
      appointments = @ubs.appointments
                         .today
                         .scheduled
                         .includes(:patient)

      @appointments = filter(search(appointments))
                      .order(:start)
                      .joins(:patient)
                      .order(Patient.arel_table[:name].lower.asc)
                      .page(index_params[:page])
                      .per([[10, index_params[:per_page].to_i].max, 10_000].min) # max of 10k is for exporting to XLS

      respond_to do |format|
        format.html
        format.xlsx do
          response.headers['Content-Disposition'] = "attachment; filename=\"vacina_agendamentos_#{Date.current}.xlsx\""
        end
      end
    end

    # rubocop:enable Metrics/AbcSize

    def show
      @appointment = @ubs.appointments.scheduled.find(params[:id])

      @other_appointments = @appointment.patient.appointments.where.not(id: @appointment.id).order(:start)

      @doses = @appointment.patient.doses.includes(:vaccine, appointment: [:ubs]).order(:created_at)

      @vaccines = Vaccine.order(:name)
    end

    # Check-in single appointment
    def check_in
      appointment = @ubs.appointments.scheduled.not_checked_in.find(params[:id])
      unless appointment.in_allowed_check_in_window?
        return redirect_to(operator_ubs_appointment_path(appointment.ubs, appointment),
                           flash: { alert: t(:"appointments.messages.not_allowed_window") })
      end

      ReceptionService.new(appointment).check_in

      redirect_to operator_ubs_appointments_path(appointment.ubs),
                  flash: { notice: "Check-in realizado para #{appointment.patient.name}." }
    end

    # Check-out single appointment
    def check_out
      appointment = @ubs.appointments.scheduled.not_checked_out.find(params[:id])
      vaccine = Vaccine.find_by id: check_out_params[:vaccine_id]

      unless vaccine
        return redirect_to(operator_ubs_appointment_path(appointment.ubs, appointment),
                           flash: { error: 'Selecione a vacina aplicada.' })
      end

      checked_out = ReceptionService.new(appointment).check_out(vaccine)

      redirect_to operator_ubs_appointment_path(appointment.ubs, appointment),
                  flash: { notice_title: notice_for_checked_out(checked_out, appointment) }
    end

    # Suspend single appointment
    def suspend
      appointment = @ubs.appointments.scheduled.not_checked_in.find(params[:id])
      appointment.update!(active: false, suspend_reason: params[:appointment][:suspend_reason])

      redirect_to operator_ubs_appointments_path(appointment.ubs),
                  flash: {
                    notice: "Agendamento suspenso para #{appointment.patient.name}"
                  }
    end

    # Activate (un-suspend) single appointment
    def activate
      appointment = @ubs.appointments.scheduled.find(params[:id])
      appointment.update!(active: true, suspend_reason: nil)

      redirect_to operator_ubs_appointment_path(appointment.ubs, appointment),
                  flash: {
                    notice: "Agendamento reativado para #{appointment.patient.name}."
                  }
    end

    private

    # Filters out appointments
    def filter(appointments)
      # use @filter from search, or input from param (permit-listed), or set to default "waiting"
      @filter ||= (FILTERS.values & [index_params[:filter].to_s]).presence&.first || FILTERS[:waiting]

      case @filter
      when FILTERS[:waiting]
        appointments.not_checked_in.not_checked_out
      when FILTERS[:checked_in]
        appointments.checked_in.not_checked_out
      when FILTERS[:checked_out]
        appointments.checked_in.checked_out
      else
        appointments
      end
    end

    # Searches for specific appointments
    def search(appointments)
      if index_params[:search].present? && index_params[:search].size >= 3
        @filter = FILTERS[:search] # In case we're searching, use special filter
        @search = index_params[:search]
        return appointments.search_for(@search)
      end

      appointments
    end

    def check_out_params
      params.permit(:vaccine_id)
    end

    def index_params
      params.permit(:per_page, :page, :search, :filter)
    end

    def notice_for_checked_out(checked_out, appointment)
      if checked_out.dose.follow_up_appointment
        I18n.t('alerts.dose_received_with_follow_up',
               name: appointment.patient.name,
               sequence_number: checked_out.dose.sequence_number,
               date: I18n.l(checked_out.next_appointment.start, format: :human))
      else
        I18n.t('alerts.last_dose_received', name: appointment.patient.name)
      end
    end

    def set_ubs
      @ubs = current_user.ubs.find(params[:ubs_id])
    end
  end
end
