import 'package:json_annotation/json_annotation.dart';

part 'model_367.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model367 {
  const Model367({required this.id, required this.value});

  final int id;
  final String value;

  factory Model367.fromJson(Map<String, dynamic> json) =>
      _$Model367FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model367ToJson(this);
}
