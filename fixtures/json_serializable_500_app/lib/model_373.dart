import 'package:json_annotation/json_annotation.dart';

part 'model_373.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model373 {
  const Model373({required this.id, required this.value});

  final int id;
  final String value;

  factory Model373.fromJson(Map<String, dynamic> json) =>
      _$Model373FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model373ToJson(this);
}
