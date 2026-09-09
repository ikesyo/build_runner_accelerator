import 'package:json_annotation/json_annotation.dart';

part 'model_150.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model150 {
  const Model150({required this.id, required this.value});

  final int id;
  final String value;

  factory Model150.fromJson(Map<String, dynamic> json) =>
      _$Model150FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model150ToJson(this);
}
