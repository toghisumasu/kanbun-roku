SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: messages_append_only(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.messages_append_only() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  RAISE EXCEPTION 'messages is append-only (% rejected)', TG_OP;
END;
$$;


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: annotations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.annotations (
    id bigint NOT NULL,
    annotatable_type character varying NOT NULL,
    annotatable_id bigint NOT NULL,
    body text NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: annotations_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.annotations_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: annotations_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.annotations_id_seq OWNED BY public.annotations.id;


--
-- Name: ar_internal_metadata; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ar_internal_metadata (
    key character varying NOT NULL,
    value character varying,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: diary_entries; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.diary_entries (
    id bigint NOT NULL,
    entry_date date NOT NULL,
    body_kanbun text,
    body_kundoku text,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: diary_entries_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.diary_entries_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: diary_entries_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.diary_entries_id_seq OWNED BY public.diary_entries.id;


--
-- Name: diary_links; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.diary_links (
    id bigint NOT NULL,
    diary_entry_id bigint NOT NULL,
    message_id bigint NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: diary_links_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.diary_links_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: diary_links_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.diary_links_id_seq OWNED BY public.diary_links.id;


--
-- Name: messages; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.messages (
    id bigint NOT NULL,
    source character varying NOT NULL,
    external_id character varying NOT NULL,
    session_id character varying NOT NULL,
    role character varying NOT NULL,
    body text NOT NULL,
    occurred_at timestamp(6) without time zone NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    raw jsonb DEFAULT '{}'::jsonb NOT NULL
);


--
-- Name: messages_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.messages_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: messages_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.messages_id_seq OWNED BY public.messages.id;


--
-- Name: schema_migrations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.schema_migrations (
    version character varying NOT NULL
);


--
-- Name: annotations id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.annotations ALTER COLUMN id SET DEFAULT nextval('public.annotations_id_seq'::regclass);


--
-- Name: diary_entries id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.diary_entries ALTER COLUMN id SET DEFAULT nextval('public.diary_entries_id_seq'::regclass);


--
-- Name: diary_links id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.diary_links ALTER COLUMN id SET DEFAULT nextval('public.diary_links_id_seq'::regclass);


--
-- Name: messages id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.messages ALTER COLUMN id SET DEFAULT nextval('public.messages_id_seq'::regclass);


--
-- Name: annotations annotations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.annotations
    ADD CONSTRAINT annotations_pkey PRIMARY KEY (id);


--
-- Name: ar_internal_metadata ar_internal_metadata_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ar_internal_metadata
    ADD CONSTRAINT ar_internal_metadata_pkey PRIMARY KEY (key);


--
-- Name: diary_entries diary_entries_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.diary_entries
    ADD CONSTRAINT diary_entries_pkey PRIMARY KEY (id);


--
-- Name: diary_links diary_links_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.diary_links
    ADD CONSTRAINT diary_links_pkey PRIMARY KEY (id);


--
-- Name: messages messages_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.messages
    ADD CONSTRAINT messages_pkey PRIMARY KEY (id);


--
-- Name: schema_migrations schema_migrations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.schema_migrations
    ADD CONSTRAINT schema_migrations_pkey PRIMARY KEY (version);


--
-- Name: index_annotations_on_annotatable; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_annotations_on_annotatable ON public.annotations USING btree (annotatable_type, annotatable_id);


--
-- Name: index_diary_entries_on_entry_date; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_diary_entries_on_entry_date ON public.diary_entries USING btree (entry_date);


--
-- Name: index_diary_links_on_diary_entry_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_diary_links_on_diary_entry_id ON public.diary_links USING btree (diary_entry_id);


--
-- Name: index_diary_links_on_diary_entry_id_and_message_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_diary_links_on_diary_entry_id_and_message_id ON public.diary_links USING btree (diary_entry_id, message_id);


--
-- Name: index_diary_links_on_message_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_diary_links_on_message_id ON public.diary_links USING btree (message_id);


--
-- Name: index_messages_on_occurred_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_messages_on_occurred_at ON public.messages USING btree (occurred_at);


--
-- Name: index_messages_on_session_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_messages_on_session_id ON public.messages USING btree (session_id);


--
-- Name: index_messages_on_source_and_external_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_messages_on_source_and_external_id ON public.messages USING btree (source, external_id);


--
-- Name: messages messages_no_truncate; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER messages_no_truncate BEFORE TRUNCATE ON public.messages FOR EACH STATEMENT EXECUTE FUNCTION public.messages_append_only();


--
-- Name: messages messages_no_update_delete; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER messages_no_update_delete BEFORE DELETE OR UPDATE ON public.messages FOR EACH ROW EXECUTE FUNCTION public.messages_append_only();


--
-- Name: diary_links fk_rails_50d10b897f; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.diary_links
    ADD CONSTRAINT fk_rails_50d10b897f FOREIGN KEY (diary_entry_id) REFERENCES public.diary_entries(id) ON DELETE CASCADE;


--
-- Name: diary_links fk_rails_55563d61e7; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.diary_links
    ADD CONSTRAINT fk_rails_55563d61e7 FOREIGN KEY (message_id) REFERENCES public.messages(id);


--
-- PostgreSQL database dump complete
--

SET search_path TO "$user", public;

INSERT INTO "schema_migrations" (version) VALUES
('20261029140000'),
('20261026142623'),
('20261026142622'),
('20261026142621'),
('20261026142620');

