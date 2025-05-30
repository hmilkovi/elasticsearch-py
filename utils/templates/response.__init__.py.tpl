#  Licensed to Elasticsearch B.V. under one or more contributor
#  license agreements. See the NOTICE file distributed with
#  this work for additional information regarding copyright
#  ownership. Elasticsearch B.V. licenses this file to you under
#  the Apache License, Version 2.0 (the "License"); you may
#  not use this file except in compliance with the License.
#  You may obtain a copy of the License at
#
# 	http://www.apache.org/licenses/LICENSE-2.0
#
#  Unless required by applicable law or agreed to in writing,
#  software distributed under the License is distributed on an
#  "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
#  KIND, either express or implied.  See the License for the
#  specific language governing permissions and limitations
#  under the License.

from typing import (
    TYPE_CHECKING,
    Any,
    Dict,
    Generic,
    Iterator,
    List,
    Mapping,
    Optional,
    Sequence,
    Tuple,
    Union,
    cast,
)

from ..utils import _R, AttrDict, AttrList, _wrap
from .hit import Hit, HitMeta

if TYPE_CHECKING:
    from ..aggs import Agg
    from ..faceted_search_base import FacetedSearchBase
    from ..search_base import Request, SearchBase
    from ..update_by_query_base import UpdateByQueryBase
    from .. import types

__all__ = ["Response", "AggResponse", "UpdateByQueryResponse", "Hit", "HitMeta", "AggregateResponseType"]


class Response(AttrDict[Any], Generic[_R]):
    """An Elasticsearch search response.

    {% for arg in response.args %}
        {% for line in arg.doc %}
    {{ line }}
        {% endfor %}
    {% endfor %}
    """
    _search: "SearchBase[_R]"
    _faceted_search: "FacetedSearchBase[_R]"
    _doc_class: Optional[_R]
    _hits: List[_R]

    {% for arg in response.args %}
        {% if arg.name not in ["hits", "aggregations"] %}
    {{ arg.name }}: {{ arg.type }}
        {% endif %}
    {% endfor %}

    def __init__(
        self,
        search: "Request[_R]",
        response: Dict[str, Any],
        doc_class: Optional[_R] = None,
    ):
        super(AttrDict, self).__setattr__("_search", search)
        super(AttrDict, self).__setattr__("_doc_class", doc_class)
        super().__init__(response)

    def __iter__(self) -> Iterator[_R]:  # type: ignore[override]
        return iter(self.hits)

    def __getitem__(self, key: Union[slice, int, str]) -> Any:
        if isinstance(key, (slice, int)):
            # for slicing etc
            return self.hits[key]
        return super().__getitem__(key)

    def __nonzero__(self) -> bool:
        return bool(self.hits)

    __bool__ = __nonzero__

    def __repr__(self) -> str:
        return "<Response: %r>" % (self.hits or self.aggregations)

    def __len__(self) -> int:
        return len(self.hits)

    def __getstate__(self) -> Tuple[Dict[str, Any], "Request[_R]", Optional[_R]]:  # type: ignore[override]
        return self._d_, self._search, self._doc_class

    def __setstate__(
        self, state: Tuple[Dict[str, Any], "Request[_R]", Optional[_R]]  # type: ignore[override]
    ) -> None:
        super(AttrDict, self).__setattr__("_d_", state[0])
        super(AttrDict, self).__setattr__("_search", state[1])
        super(AttrDict, self).__setattr__("_doc_class", state[2])

    def success(self) -> bool:
        return self._shards.total == self._shards.successful and not self.timed_out

    @property
    def hits(self) -> List[_R]:
        if not hasattr(self, "_hits"):
            h = cast(AttrDict[Any], self._d_["hits"])

            try:
                hits = AttrList(list(map(self._search._get_result, h["hits"])))
            except AttributeError as e:
                # avoid raising AttributeError since it will be hidden by the property
                raise TypeError("Could not parse hits.", e)

            # avoid assigning _hits into self._d_
            super(AttrDict, self).__setattr__("_hits", hits)
            for k in h:
                setattr(self._hits, k, _wrap(h[k]))
        return self._hits

    @property
    def aggregations(self) -> "AggResponse[_R]":
        return self.aggs

    @property
    def aggs(self) -> "AggResponse[_R]":
        if not hasattr(self, "_aggs"):
            aggs = AggResponse[_R](
                cast("Agg[_R]", self._search.aggs),
                self._search,
                cast(Dict[str, Any], self._d_.get("aggregations", {})),
            )

            # avoid assigning _aggs into self._d_
            super(AttrDict, self).__setattr__("_aggs", aggs)
        return cast("AggResponse[_R]", self._aggs)

    def search_after(self) -> "SearchBase[_R]":
        """
        Return a ``Search`` instance that retrieves the next page of results.

        This method provides an easy way to paginate a long list of results using
        the ``search_after`` option. For example::

            page_size = 20
            s = Search()[:page_size].sort("date")

            while True:
                # get a page of results
                r = await s.execute()

                # do something with this page of results

                # exit the loop if we reached the end
                if len(r.hits) < page_size:
                    break

                # get a search object with the next page of results
                s = r.search_after()

        Note that the ``search_after`` option requires the search to have an
        explicit ``sort`` order.
        """
        if len(self.hits) == 0:
            raise ValueError("Cannot use search_after when there are no search results")
        if not hasattr(self.hits[-1].meta, "sort"):  # type: ignore[attr-defined]
            raise ValueError("Cannot use search_after when results are not sorted")
        return self._search.extra(search_after=self.hits[-1].meta.sort)  # type: ignore[attr-defined]


AggregateResponseType = {{ response["aggregate_type"] }}


class AggResponse(AttrDict[Any], Generic[_R]):
    """An Elasticsearch aggregation response."""
    _meta: Dict[str, Any]

    def __init__(self, aggs: "Agg[_R]", search: "Request[_R]", data: Dict[str, Any]):
        super(AttrDict, self).__setattr__("_meta", {"search": search, "aggs": aggs})
        super().__init__(data)

    def __getitem__(self, attr_name: str) -> AggregateResponseType:
        if attr_name in self._meta["aggs"]:
            # don't do self._meta['aggs'][attr_name] to avoid copying
            agg = self._meta["aggs"].aggs[attr_name]
            return cast(AggregateResponseType, agg.result(self._meta["search"], self._d_[attr_name]))
        return super().__getitem__(attr_name)  # type: ignore[no-any-return]

    def __iter__(self) -> Iterator[AggregateResponseType]:  # type: ignore[override]
        for name in self._meta["aggs"]:
            yield self[name]


class UpdateByQueryResponse(AttrDict[Any], Generic[_R]):
    """An Elasticsearch update by query response.

    {% for arg in ubq_response.args %}
        {% for line in arg.doc %}
    {{ line }}
        {% endfor %}
    {% endfor %}
    """
    _search: "UpdateByQueryBase[_R]"

    {% for arg in ubq_response.args %}
    {{ arg.name }}: {{ arg.type }}
    {% endfor %}

    def __init__(
        self,
        search: "Request[_R]",
        response: Dict[str, Any],
        doc_class: Optional[_R] = None,
    ):
        super(AttrDict, self).__setattr__("_search", search)
        super(AttrDict, self).__setattr__("_doc_class", doc_class)
        super().__init__(response)

    def success(self) -> bool:
        return not self.timed_out and not self.failures
