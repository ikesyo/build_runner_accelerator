import 'package:json_annotation/json_annotation.dart';

part 'model_020.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model020 {
  const Model020({required this.id, required this.value});

  final int id;
  final String value;

  factory Model020.fromJson(Map<String, dynamic> json) =>
      _$Model020FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model020ToJson(this);
}
