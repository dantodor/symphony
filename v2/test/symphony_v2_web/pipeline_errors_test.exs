defmodule SymphonyV2Web.PipelineErrorsTest do
  use ExUnit.Case, async: true

  alias SymphonyV2Web.PipelineErrors

  describe "format/1" do
    test "formats :not_awaiting_plan_review" do
      assert PipelineErrors.format(:not_awaiting_plan_review) =~
               "no longer awaiting plan review"
    end

    test "formats :not_awaiting_final_review" do
      assert PipelineErrors.format(:not_awaiting_final_review) =~
               "no longer awaiting final review"
    end

    test "formats :not_processing" do
      assert PipelineErrors.format(:not_processing) =~ "not currently processing"
    end

    test "formats :pipeline_idle" do
      assert PipelineErrors.format(:pipeline_idle) =~ "idle"
    end

    test "formats :self_review" do
      assert PipelineErrors.format(:self_review) =~ "cannot approve your own"
    end

    test "formats {:invalid_transition, from, to}" do
      msg = PipelineErrors.format({:invalid_transition, "draft", "completed"})
      assert msg =~ "draft"
      assert msg =~ "completed"
    end

    test "formats {:merge_failed, reason}" do
      assert PipelineErrors.format({:merge_failed, "conflict"}) =~ "Merge failed"
    end

    test "formats {:safehouse_not_found, msg}" do
      assert PipelineErrors.format({:safehouse_not_found, "missing binary"}) =~
               "sandbox not available"
    end

    test "formats {:pr_parse_failed, output}" do
      assert PipelineErrors.format({:pr_parse_failed, "garbage"}) =~ "parse PR"
    end

    test "formats binary reasons as-is" do
      assert PipelineErrors.format("custom error message") == "custom error message"
    end

    test "formats unknown terms with inspect" do
      assert PipelineErrors.format(:some_unknown_error) =~ "Operation failed"
      assert PipelineErrors.format(:some_unknown_error) =~ "some_unknown_error"
    end
  end
end
