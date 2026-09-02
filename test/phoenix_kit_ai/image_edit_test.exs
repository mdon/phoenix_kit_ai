defmodule PhoenixKitAI.ImageEditTest do
  @moduledoc """
  Tests for the image-editing path: `Completion.edit_image/4` and the
  public `PhoenixKitAI.edit_image/4` entry point.

  Two transports are covered: the chat-completions multimodal path
  (OpenRouter → Gemini image models, images on `message.images`) and
  xAI's `/images/edits` JSON endpoint. Every request body is captured by
  the `Req.Test` stub and asserted on, because the transport differences
  (`modalities`, `usage.include`, the `image` field) are the whole point.
  """

  use PhoenixKitAI.DataCase, async: false

  import Ecto.Query

  alias PhoenixKitAI.{Completion, Request}
  alias PhoenixKitAI.Test.Repo, as: TestRepo

  @png <<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A>>
  @jpeg <<0xFF, 0xD8, 0xFF, 0xE0, 0, 16, "JFIF">>

  setup do
    Application.put_env(:phoenix_kit_ai, :req_options,
      plug: {Req.Test, PhoenixKitAI.ImageEditTest},
      retry: false
    )

    {:ok, _} =
      PhoenixKit.Settings.update_json_setting(
        "integration:openrouter:default",
        %{"api_key" => "sk-test-key", "status" => "connected", "provider" => "openrouter"}
      )

    on_exit(fn ->
      Application.delete_env(:phoenix_kit_ai, :req_options)
    end)

    :ok
  end

  # Stub that records the JSON body and request path in the test process
  # (Req.Test runs the plug in the calling process) and answers `body`.
  defp stub_capturing(status, body) do
    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:request, conn.request_path, Jason.decode!(raw)})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(status, Jason.encode!(body))
    end)
  end

  defp endpoint_fixture(attrs \\ %{}) do
    base = %{
      name: "Edit-EP-#{System.unique_integer([:positive])}",
      provider: "openrouter",
      model: "google/gemini-2.5-flash-image",
      api_key: "sk-test-key"
    }

    {:ok, ep} = PhoenixKitAI.create_endpoint(Map.merge(base, attrs))
    ep
  end

  defp data_url(bytes, type), do: "data:#{type};base64," <> Base.encode64(bytes)

  defp chat_payload(message, usage \\ %{"prompt_tokens" => 1290, "completion_tokens" => 1300}) do
    %{
      "id" => "gen-edit-1",
      "model" => "google/gemini-2.5-flash-image",
      "choices" => [%{"message" => Map.merge(%{"role" => "assistant"}, message)}],
      "usage" => usage
    }
  end

  defp inputs,
    do: [%{data: @jpeg, content_type: "image/jpeg"}, %{data: @png, content_type: "image/png"}]

  defp logged_requests do
    TestRepo.all(
      from(r in Request, where: r.request_type == "image_edit", order_by: r.inserted_at)
    )
  end

  describe "chat-completions transport (OpenRouter)" do
    test "sends prompt + images in order with OpenRouter's image fields and decodes message.images" do
      stub_capturing(
        200,
        chat_payload(
          %{
            "content" => "",
            "images" => [
              %{"type" => "image_url", "image_url" => %{"url" => data_url(@png, "image/png")}}
            ]
          },
          %{"prompt_tokens" => 1290, "completion_tokens" => 1300, "cost" => 0.0123}
        )
      )

      ep = endpoint_fixture()

      assert {:ok, %{images: [%{data: @png, url: nil, content_type: "image/png"}], text: nil}} =
               PhoenixKitAI.edit_image(
                 ep.uuid,
                 "Restyle the first photo like the second.",
                 inputs(),
                 image_config: %{"aspect_ratio" => "4:3"}
               )

      assert_received {:request, "/api/v1/chat/completions", body}
      assert body["model"] == "google/gemini-2.5-flash-image"
      assert body["modalities"] == ["image", "text"]
      assert body["usage"] == %{"include" => true}
      assert body["image_config"] == %{"aspect_ratio" => "4:3"}

      assert [%{"role" => "user", "content" => [text_part, first, second]}] = body["messages"]

      assert text_part == %{
               "type" => "text",
               "text" => "Restyle the first photo like the second."
             }

      assert first == %{
               "type" => "image_url",
               "image_url" => %{"url" => data_url(@jpeg, "image/jpeg")}
             }

      assert second == %{
               "type" => "image_url",
               "image_url" => %{"url" => data_url(@png, "image/png")}
             }

      # Logged as its own request type, with the provider-reported cost in nanodollars.
      assert [req] = logged_requests()
      assert req.status == "success"
      assert req.model == "google/gemini-2.5-flash-image"
      assert req.input_tokens == 1290
      assert req.output_tokens == 1300
      assert req.cost_cents == 12_300
      assert req.metadata["input_image_count"] == 2
      assert req.metadata["input_bytes"] == byte_size(@jpeg) + byte_size(@png)
      assert req.metadata["output_image_count"] == 1
      assert req.metadata["output_bytes"] == byte_size(@png)
      assert req.metadata["input"] == "Restyle the first photo like the second."
      refute Map.has_key?(req.metadata, "images")
    end

    test "accepts an image content part and returns the prose alongside it" do
      stub_capturing(
        200,
        chat_payload(%{
          "content" => [
            %{"type" => "text", "text" => "Here is your kitchen in white oak."},
            %{"type" => "image_url", "image_url" => %{"url" => data_url(@png, "image/png")}}
          ]
        })
      )

      ep = endpoint_fixture()

      assert {:ok, %{images: [%{data: @png, content_type: "image/png"}], text: text}} =
               PhoenixKitAI.edit_image(ep.uuid, "Restyle", [data_url(@jpeg, "image/jpeg")])

      assert text == "Here is your kitchen in white oak."
      assert [%{metadata: %{"response" => ^text}}] = logged_requests()
    end

    test "an http URL result is passed through without bytes" do
      stub_capturing(
        200,
        chat_payload(%{
          "content" => nil,
          "images" => [
            %{"type" => "image_url", "image_url" => %{"url" => "https://cdn.example/out.png"}}
          ]
        })
      )

      ep = endpoint_fixture()

      assert {:ok,
              %{images: [%{data: nil, url: "https://cdn.example/out.png", content_type: nil}]}} =
               PhoenixKitAI.edit_image(ep.uuid, "Restyle", [%{url: "https://example.com/in.jpg"}])

      assert_received {:request, _, body}
      [%{"content" => [_text, image_part]}] = body["messages"]
      assert image_part["image_url"]["url"] == "https://example.com/in.jpg"
    end

    test "prose-only answers surface as no_image_in_response with the prose, and log an error" do
      stub_capturing(200, chat_payload(%{"content" => "I can't modify photos of people."}))
      ep = endpoint_fixture()

      assert {:error, {:no_image_in_response, "I can't modify photos of people."}} =
               PhoenixKitAI.edit_image(ep.uuid, "Restyle", inputs())

      assert [req] = logged_requests()
      assert req.status == "error"
      assert req.error_message == "The model returned no image"
      assert req.metadata["error_reason"] =~ "no_image_in_response"
    end

    test "providers other than OpenRouter get neither modalities nor usage.include" do
      stub_capturing(
        200,
        chat_payload(%{"images" => [%{"image_url" => %{"url" => data_url(@png, "image/png")}}]})
      )

      ep =
        endpoint_fixture(%{
          provider: "openai",
          model: "gpt-5-image",
          base_url: "https://api.openai.com/v1"
        })

      assert {:ok, %{images: [%{data: @png}]}} =
               PhoenixKitAI.edit_image(ep.uuid, "Restyle", inputs())

      assert_received {:request, "/v1/chat/completions", body}
      refute Map.has_key?(body, "modalities")
      refute Map.has_key?(body, "usage")
    end

    test "maps error statuses through the shared vocabulary" do
      stub_capturing(402, %{"error" => %{"message" => "Insufficient credits"}})
      ep = endpoint_fixture()

      assert {:error, :insufficient_credits} =
               PhoenixKitAI.edit_image(ep.uuid, "Restyle", inputs())

      assert [%{status: "error", error_message: "Insufficient credits"}] = logged_requests()
    end
  end

  describe "xAI transport (/images/edits)" do
    test "posts prompt + image list as JSON and decodes b64_json results" do
      stub_capturing(200, %{"data" => [%{"b64_json" => Base.encode64(@png)}]})

      ep = endpoint_fixture(%{provider: "xai", model: "grok-imagine-image-2.0"})

      assert {:ok, %{images: [%{data: @png, url: nil, content_type: nil}], text: nil}} =
               PhoenixKitAI.edit_image(ep.uuid, "Restyle", inputs(), n: 1, resolution: "1k")

      assert_received {:request, "/v1/images/edits", body}
      assert body["model"] == "grok-imagine-image-2.0"
      assert body["prompt"] == "Restyle"
      assert body["n"] == 1
      assert body["resolution"] == "1k"
      refute Map.has_key?(body, "modalities")

      assert [
               %{"url" => first, "type" => "image_url"},
               %{"url" => second, "type" => "image_url"}
             ] = body["image"]

      assert first == data_url(@jpeg, "image/jpeg")
      assert second == data_url(@png, "image/png")

      assert [%{status: "success", request_type: "image_edit", cost_cents: nil}] =
               logged_requests()
    end

    test "a single input is sent as one image object" do
      stub_capturing(200, %{"data" => [%{"url" => "https://imgen.x.ai/out.png"}]})
      ep = endpoint_fixture(%{provider: "xai", model: "grok-imagine-image-2.0"})

      assert {:ok, %{images: [%{url: "https://imgen.x.ai/out.png", data: nil}]}} =
               PhoenixKitAI.edit_image(ep.uuid, "Restyle", [
                 %{data: @jpeg, content_type: "image/jpeg"}
               ])

      assert_received {:request, "/v1/images/edits", body}
      assert %{"url" => _, "type" => "image_url"} = body["image"]
    end
  end

  describe "input validation" do
    test "rejects an empty list and malformed entries before any HTTP call" do
      ep = endpoint_fixture()

      assert {:error, :empty_input} = PhoenixKitAI.edit_image(ep.uuid, "Restyle", [])

      assert {:error, :invalid_image_input} =
               PhoenixKitAI.edit_image(ep.uuid, "Restyle", [
                 %{data: "", content_type: "image/png"}
               ])

      assert {:error, :invalid_image_input} =
               PhoenixKitAI.edit_image(ep.uuid, "Restyle", ["not-a-url"])

      assert {:error, :invalid_image_input} =
               PhoenixKitAI.edit_image(ep.uuid, "Restyle", [%{data: @png}])

      refute_received {:request, _, _}
      # Validation failures are still logged so operators see misuse.
      assert Enum.all?(logged_requests(), &(&1.status == "error"))
    end

    test "endpoint problems short-circuit like every other verb" do
      ep = endpoint_fixture()
      {:ok, ep} = PhoenixKitAI.update_endpoint(ep, %{enabled: false})

      assert {:error, :endpoint_disabled} = PhoenixKitAI.edit_image(ep.uuid, "Restyle", inputs())

      assert {:error, :endpoint_not_found} =
               PhoenixKitAI.edit_image(Ecto.UUID.generate(), "Restyle", inputs())

      assert logged_requests() == []
    end
  end

  describe "Completion.decode_image_url/1" do
    test "splits base64 data URLs into bytes and MIME type" do
      assert %{data: @png, url: nil, content_type: "image/png"} =
               Completion.decode_image_url("data:image/png;base64," <> Base.encode64(@png))
    end

    test "tolerates a missing MIME type and malformed base64" do
      assert %{data: "abc", content_type: nil} = Completion.decode_image_url("data:,abc")
      assert %{data: nil, url: nil} = Completion.decode_image_url("data:image/png;base64,***")
    end

    test "passes http URLs through" do
      assert %{data: nil, url: "https://x/y.png"} = Completion.decode_image_url("https://x/y.png")
    end
  end
end
