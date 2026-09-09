import 'package:json_annotation/json_annotation.dart';

part 'model_268.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model268 {
  const Model268({required this.id, required this.value});

  final int id;
  final String value;

  factory Model268.fromJson(Map<String, dynamic> json) =>
      _$Model268FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model268ToJson(this);
}
