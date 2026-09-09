import 'package:json_annotation/json_annotation.dart';

part 'model_213.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model213 {
  const Model213({required this.id, required this.value});

  final int id;
  final String value;

  factory Model213.fromJson(Map<String, dynamic> json) =>
      _$Model213FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model213ToJson(this);
}
