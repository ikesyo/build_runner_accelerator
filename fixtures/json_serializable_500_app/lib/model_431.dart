import 'package:json_annotation/json_annotation.dart';

part 'model_431.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model431 {
  const Model431({required this.id, required this.value});

  final int id;
  final String value;

  factory Model431.fromJson(Map<String, dynamic> json) =>
      _$Model431FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model431ToJson(this);
}
