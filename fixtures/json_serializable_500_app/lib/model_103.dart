import 'package:json_annotation/json_annotation.dart';

part 'model_103.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model103 {
  const Model103({required this.id, required this.value});

  final int id;
  final String value;

  factory Model103.fromJson(Map<String, dynamic> json) =>
      _$Model103FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model103ToJson(this);
}
