import 'package:json_annotation/json_annotation.dart';

part 'model_119.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model119 {
  const Model119({required this.id, required this.value});

  final int id;
  final String value;

  factory Model119.fromJson(Map<String, dynamic> json) =>
      _$Model119FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model119ToJson(this);
}
