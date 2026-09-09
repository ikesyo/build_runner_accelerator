import 'package:json_annotation/json_annotation.dart';

part 'model_260.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model260 {
  const Model260({required this.id, required this.value});

  final int id;
  final String value;

  factory Model260.fromJson(Map<String, dynamic> json) =>
      _$Model260FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model260ToJson(this);
}
